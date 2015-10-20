open Core.Std
open Async.Std
open Cohttp
open Cohttp_async

type t = { endpoint: Uri.t }

module Service = struct
  type id = ID of string
  type name = Name of string

  let of_string s = Name s
end

module RunMonitor = struct
  type t = Monitor of (unit Ivar .t * (bool ref))

  let create () = (Monitor (Ivar.create (), ref true))

  let completed (Monitor (v, _)) = Ivar.fill v ()

  let is_running (Monitor (_, is_running)) = !is_running = true

  let close (Monitor (v, is_running)) = is_running := false; Ivar.read v

  let closer m = fun _ -> close m
end

let create endpoint = { endpoint = Uri.of_string endpoint }

let uri ?(query_params = []) t path =
  (Uri.with_path t.endpoint path |> Uri.with_query) query_params

let parse_discovery_body body =
  let open Yojson.Basic.Util in
  let parse_pair pair = (pair |> member "Node" |> member "Address" |> to_string,
                         pair |> member "Service" |> member "Port" |> to_int) in
  let parse () = Yojson.Basic.from_string body |> to_list |> List.map ~f: parse_pair in
  try Ok (parse ())
  with exc -> Error "Parsing failed"

let parse_kv_body body = Ok body

let try_def ?(extract_exn = true) d =
  try_with ~extract_exn:extract_exn (fun _ -> d)

let requests_loop parser uri monitor w =
  let rec loop last_res index =
    if RunMonitor.is_running monitor then
      let try_again () = Time.Span.of_int_sec 2 |> after >>= fun _ -> loop last_res index in
      let uri2 = match index with
        | Some index2 -> Uri.add_query_params' uri [("index", index2); ("wait", "10s")]
        | None -> uri in
      let do_req () = Client.get uri2 >>= fun (resp, body) ->
        match Response.status resp with
        | #Code.success_status ->
          let index2 = Header.get resp.Response.headers "x-consul-index" in
          if index = index2 then loop last_res index
          else (Body.to_string body) >>= fun body' -> parser body' |> (function
              | Ok parsed ->
                (match last_res with
                 | Some last_res' when last_res' = parsed -> loop last_res index2
                 | _ -> Pipe.write w parsed >>= fun _ -> loop last_res index2)
              | Error error -> print_endline ("Error in parsing " ^ error); try_again ())
        | #Code.client_error_status -> Pipe.close w; RunMonitor.completed monitor; return ()
        | _ -> print_endline "Error in response";
          try_again () in
      print_endline ("Request: " ^ Uri.to_string uri2);
      try_with ~extract_exn:true do_req >>= (function
          | Ok _ -> return ()
          | Error e ->
            e |> sexp_of_exn |> Sexp.to_string_hum |> print_endline;
            try_again ())
    else RunMonitor.completed monitor |> return in
  loop None None

let watch_uri t parser uri =
  let monitor = RunMonitor.create () in
  let w = requests_loop parser uri monitor in
  let r = Pipe.init w in
  (r, RunMonitor.closer monitor)

let key t k =
  let uri = uri t ("/v1/kv/" ^ k) in
  Uri.with_query uri [("raw", [])] |> watch_uri t parse_kv_body

let discovery t ?tag (Service.Name service) =
  let uri = uri t ("/v1/health/service/" ^ service) in
  let uri' = match tag with
    | Some v -> Uri.add_query_param' uri ("tag", v)
    | None -> uri in
  Uri.with_query uri' [("raw", [])] |> watch_uri t parse_discovery_body

module RegisterService = struct
  type check = {
    script: string [@key "Script"];
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

exception BadStatus of Cohttp.Code.status_code
let not_200_as_error (resp, body) =
  let r = match Response.status resp with
    | #Code.success_status -> Ok (resp, body)
    | status -> Error (BadStatus status) in
  return r

let register_service t ?(id_suffix="") spec =
  let open Spec in
  let uri = uri t "/v1/agent/service/register" in
  let (script, check_interval) = (spec.check.script, spec.check.interval) in
  let id = spec.name ^ "_" ^ id_suffix in
  let req = { RegisterService.
              id = id;
              name = spec.name;
              tags = spec.tags;
              port = spec.port;
              check = { RegisterService.
                        script = script;
                        interval = Time.Span.(check_interval |> of_int_sec |> to_short_string)}} in
  let body = RegisterService.to_yojson req |> Yojson.Safe.to_string |> Body.of_string in
  try_with (fun _ -> Client.post ~body: body uri) >>=?
  not_200_as_error >>|? fun _ -> Service.ID id

let deregister_service t (Service.ID id) =
  let uri = uri t ("/v1/agent/service/deregister/" ^ id) in
  try_with (fun _ -> Client.delete uri) >>|? fun _ -> ()

let parse_checks_body body =
  let open Yojson.Basic.Util in
  let parse v = v |> member "Status" |> to_string  in
  let parse' () = Yojson.Basic.from_string body |> Yojson.Basic.Util.to_assoc |> List.Assoc.map ~f:parse in
  try Ok (parse' ())
  with exc -> Error (Failure "Parsing failed")

let wait_for_passing_loop t (Service.ID service_id) timeout monitor =
  let uri = uri t ("/v1/agent/checks") in
  let rec tick () =
    if RunMonitor.is_running monitor then
      (try_with (fun _ -> Client.get uri) >>=?
       not_200_as_error >>=? fun (resp, body) ->
       try_with (fun _ -> Body.to_string body) >>=? fun body' ->
       parse_checks_body body' |> return  >>=? fun checks ->
       List.Assoc.find checks service_id |> fun op ->
       Result.of_option op (Failure "unknown service_id") |> return) >>= function
      | Error _ -> tick ()
      | Ok _ -> return `Up
    else
      (RunMonitor.completed monitor;
       return `Closed) in
  with_timeout timeout (tick ()) >>| function
  | `Timeout -> Error (Failure ("Service timeout " ^ service_id))
  | `Result v -> Ok v

let wait_for_passing t service_ids =
  let make (service_id, timeout) =
    let monitor = RunMonitor.create () in
    (monitor, wait_for_passing_loop t service_id timeout monitor) in
  let loops = List.map service_ids make in
  let deferreds = List.map loops snd in
  let monitors = List.map loops fst in
  let closer () = List.map monitors RunMonitor.close |> Deferred.all >>| fun _ -> () in
  let res = Utils.Deferred.all_or_error deferreds >>| function
    | Ok v -> (match List.for_all v (function `Up -> true | _ -> false) with
        | true -> Ok ()
        | false -> Error (Failure "Closed"))
    | Error err -> Error err in
  (res, closer)
