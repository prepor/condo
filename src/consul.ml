open Core.Std
open Async.Std
open Cohttp
open Cohttp_async

module RM = Utils.RunMonitor

type t = { endpoint: Uri.t }

module Service = struct
  type id = ID of string
  type name = Name of string

  let of_string s = Name s
end

let create endpoint = { endpoint = Uri.of_string endpoint }

let make_uri ?(query_params = []) t path =
  (Uri.with_path t.endpoint path |> Uri.with_query) query_params

let parse_discovery_body body =
  let open Yojson.Basic.Util in
  let parse_pair pair = (pair |> member "Node" |> member "Address" |> to_string,
                         pair |> member "Service" |> member "Port" |> to_int) in
  let parse () = Yojson.Basic.from_string body |> to_list |> List.map ~f: parse_pair in
  try Ok (parse ())
  with exc -> Error ("Parsing failed" ^ Utils.exn_to_string exc)

let parse_kv_body body = Ok body

let try_def ?(extract_exn = true) d =
  try_with ~extract_exn:extract_exn (fun _ -> d)

let requests_loop parser uri monitor w =
  let guarded_write v =
    if RM.is_running monitor then Pipe.write w v
    else return () in
  let get_key last_res index =
    let uri' = match index with
      | Some index2 -> Uri.add_query_params' uri [("index", index2); ("wait", "10s")]
      | None -> uri in
    let do_req () =
      L.debug "Consul watcher %s: do request" (Uri.to_string uri);
      Client.get uri' >>= fun (resp, body) ->
      match Response.status resp with
      | #Code.success_status ->
        (match (index, Header.get resp.Response.headers "x-consul-index") with
         | (None, None) -> Error `SameIndex |> return
         | (Some index, Some index2) when index = index2 -> Error `SameIndex |> return
         | (Some index, None) -> Error `UnknownIndex |> return
         | (_, Some index2) ->
           (Body.to_string body) >>| fun body' -> parser body' |> (function
               | Ok parsed -> (match last_res with
                   | Some last_res' when last_res' = parsed -> Error (`SameValue index2)
                   | _ -> Ok (parsed, index2))
               | Error error -> Error (`ParsingError (index2, error))))
      | status ->
        Error (`BadStatus status) |> return in
    try_with ~extract_exn:true do_req >>= function
    | Ok (Ok v) -> `Key v |> return
    | Ok (Error v) -> return v
    | Error exn -> `ConnectionError exn |> return in

  let rec loop last_res index =
    if RM.is_running monitor then
      let try_again () = Time.Span.of_int_sec 2 |> after >>= fun _ -> loop last_res index in
      let uri_s = (Uri.to_string uri) in
      get_key last_res index >>= function
      | `Key (res, index') ->
        guarded_write res >>= fun () ->
        loop (Some res) (Some index')
      | `SameValue index' ->
        L.debug "Consul watcher %s: same value, do again" uri_s;
        loop last_res (Some index')
      | `SameIndex ->
        L.debug "Consul watcher %s: same index, do again" uri_s;
        loop last_res index
      (* it impossible if consul works correctly *)
      | `UnknownIndex ->
        L.error "Consul watcher %s: none index, try again" uri_s;
        try_again ()
      | `ParsingError (index', err) ->
        L.error "Consul watcher %s: parsing error, try again" err;
        loop last_res (Some index')
      | `BadStatus status ->
        L.error "Consul watcher %s: bad status %s, try again" uri_s (Cohttp.Code.string_of_status status);
        try_again ()
      | `ConnectionError exn ->
        L.error "Consul watcher %s: connection error %s, try again\n" uri_s (Utils.of_exn exn);
        try_again ()
    else RM.completed monitor |> return in
  loop None None

let watch_uri t parser uri =
  let monitor = RM.create () in
  let w = requests_loop parser uri monitor in
  let r = Pipe.init w in
  (r, RM.closer monitor)

let key t k =
  let uri = make_uri t ("/v1/kv" ^ k) in
  Uri.with_query uri [("raw", [])] |> watch_uri t parse_kv_body

let discovery t ?tag (Service.Name service) =
  let uri = make_uri t ("/v1/health/service/" ^ service) in
  let uri' = match tag with
    | Some v -> Uri.add_query_param' uri ("tag", v)
    | None -> uri in
  Uri.with_query uri' [("raw", [])] |> watch_uri t parse_discovery_body

module RegisterService = struct
  type check = {
    script: string option [@key "Script"];
    http: string option [@key "HTTP"];
    interval: string [@key "Interval"];
  } [@@deriving yojson, show]
  type t = {
    id: string [@key "ID"];
    name: string [@key "Name"];
    tags: string list [@key "Tags"];
    port: int [@key "Port"];
    check: check [@key "Check"]
  } [@@deriving yojson, show]
end

let register_service t ?(id_suffix="") spec port =
  let open Spec.Service in
  let uri = make_uri t "/v1/agent/service/register" in
  let {Spec.Check.interval} = spec.check in
  let id = spec.name ^ "_" ^ id_suffix in
  let (script, http) = Spec.Check.(match spec.check.method_ with
      | HTTP v -> (None, Some v)
      | Script v -> (Some v, None)) in
  let req = { RegisterService.
              id = id;
              name = spec.name;
              tags = spec.tags;
              port = port;
              check = { RegisterService.
                        script = script;
                        http = http;
                        interval = Time.Span.(interval |> of_int_sec |> to_short_string)}} in
  let body = RegisterService.to_yojson req |> Yojson.Safe.to_string |> Body.of_string in
  L.info "Register service %s on port %i" id port;
  try_with (fun _ -> Client.post ~body: body uri) >>=?
  Utils.HTTP.not_200_as_error >>|? fun _ -> Service.ID id

let deregister_service t (Service.ID id) =
  let uri = make_uri t ("/v1/agent/service/deregister/" ^ id) in
  L.info"Deregister service %s" id;
  try_with (fun _ -> Client.delete uri) >>|? fun _ -> ()

let parse_checks_body id body =
  let open Yojson.Basic.Util in
  let body' = Yojson.Basic.from_string body in
  let parse' () = Yojson.Basic.Util.(body' |> member (sprintf "service:%s" id) |> member "Status" |> to_string )
                  |> (=) "passing" in
  try Ok (parse' ())
  with exc -> Error (Failure ("Parsing failed" ^ Utils.exn_to_string exc))

let wait_for_passing_loop t (Service.ID service_id) timeout is_running =
  let uri = make_uri t ("/v1/agent/checks") in
  let rec tick () =
    L.debug "Waiting for %s" service_id;
    if !is_running then
      (try_with (fun _ -> Client.get uri) >>=?
       Utils.HTTP.not_200_as_error >>=? fun (resp, body) ->
       try_with (fun _ -> Body.to_string body) >>=? fun body' ->
       parse_checks_body service_id body' |> return  >>=? fun is_passing ->
       if is_passing then Ok () |> return
       else Error (Failure "Service is down") |> return
      ) >>= function
      | Error err -> after (Time.Span.of_int_sec 1) >>= tick
      | Ok () -> Ok () |> return
    else
      Error (Failure "Closed") |> return in
  with_timeout timeout (tick ()) >>| function
  | `Timeout -> Error (Failure ("Timeouted " ^ service_id))
  | `Result Error err -> Error err
  | `Result Ok () -> Ok ()

let wait_for_passing t service_ids =
  let is_running = ref true in
  let make (service_id, timeout) = wait_for_passing_loop t service_id timeout is_running in
  let deferreds = List.map service_ids make in
  let res = Utils.Deferred.all_or_error deferreds >>| function
    | Ok _ -> `Pass
    | Error err ->
      if !is_running then `Error err
      else `Closed in
  (res, fun () -> is_running := false)
