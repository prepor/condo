open! Core.Std
open! Async.Std

module type KV = sig
  val put : key:string -> data:string -> unit
  val get_all : ?prefix:string -> unit -> ((string * string) list, string) Deferred.Result.t
end

module Consul = struct
  (* We send accept header with each request, because without it consul doesn't
     work with persistent connections ^_^ *)
  module Cancel = Condo_cancellable
  module Queue = Condo_window_queue
  type t = {
    id : string;
    endpoint : Async_http.addr;
    prefix : string;
    queue : (string * string) Queue.t
  }

  let create_session t =
    let tick () =
      match%map Async_http.(request_of_addr t.endpoint
                            |> path "/v1/session/create"
                            |> body (Yojson.Basic.to_string (`Assoc ["TTL", `String "10s";
                                                                     "Behavior", `String "delete"]))
                            |> parser (fun v -> Yojson.Basic.(from_string v
                                                              |> Util.member "ID"
                                                              |> Util.to_string))
                            |> put) with
      | Ok {Async_http.Response.body} -> `Complete body
      | Error err ->
          Logs.err (fun m -> m "Error while creating session in consul: %s" (Exn.to_string err));
          `Continue () in
    Cancel.worker ~sleep:5000 ~tick:(Cancel.wrap_tick tick) () |> Cancel.wait_exn

  let renew_session t session =
    let tick session =
      match%bind Async_http.(request_of_addr t.endpoint
                             |> path (sprintf "/v1/session/renew/%s" session)
                             |> body ""
                             |> put) with
      | Ok {Async_http.Response.body} -> return @@ `Complete session
      | Error err ->
          Logs.err (fun m -> m "Error while renewing session in consul: %s" (Exn.to_string err));
          let%map session' = create_session t in
          `Complete session' in
    Cancel.worker ~sleep:5000 ~tick:(Cancel.wrap_tick tick) session |> Cancel.wait_exn

  let put' t ~session ~key ~data =
    let tick (is_new, session) =
      match%bind Async_http.(request_of_addr t.endpoint
                             |> path Filename.(concat "/v1/kv/" @@ concat t.prefix @@ sprintf "%s_%s" key t.id)
                             |> query_param "acquire" session
                             |> body data
                             |> put) with
      | Ok {Async_http.Response.body} ->
          (match body with
          | "true" -> return @@ `Complete (if is_new then `New_session session else `Ok)
          | _ -> Logs.err (fun m -> m "Unsuccessful putting key to consul, consul returned: %s" body);
              let%map session' = create_session t in
              `Continue (true, session'))
      | Error err ->
          Logs.err (fun m -> m "Error while putting key to consul: %s" (Exn.to_string err));
          return @@ `Continue (is_new, session) in
    Cancel.worker ~sleep:5000 ~tick:(Cancel.wrap_tick tick) (false, session) |> Cancel.wait_exn

  let worker t =
    let renew_sleep () = (after (Time.Span.of_int_sec 5)) in
    let tick (reader, renew_session_sleep, session) =
      choose [
        choice renew_session_sleep (fun () ->
            let%map session = renew_session t session in
            `Continue (reader, renew_sleep (), session));
        choice reader (fun (key, data) -> match%map put' t ~session ~key ~data with
          | `Ok -> `Continue ((Queue.read t.queue), renew_session_sleep, session)
          | `New_session session -> `Continue ((Queue.read t.queue), renew_sleep (), session))]
      |> Deferred.join in
    let%map session = create_session t in
    Cancel.worker ~tick:(Cancel.wrap_tick tick) ((Queue.read t.queue), renew_sleep (), session) |> ignore

  let create ~endpoint ~prefix =
    let t = {id = Condo_utils.random_str 10; endpoint; prefix; queue = Queue.create ~size:50} in
    worker t |> don't_wait_for;
    t

  let put t ~key ~data =
    Queue.write t.queue (key, data)

  let get_all t ?prefix () =
    let prefix' = match prefix with
    | Some v -> Filename.concat t.prefix v
    | None -> t.prefix in
    let extract_name key =
      Filename.basename key
      |> String.split ~on:'_'
      |> List.rev |> List.tl_exn |> List.rev
      |> String.concat ~sep:"_" in
    let parse v = Yojson.Basic.(from_string v
                                |> Util.to_list
                                |> List.map ~f:(fun v ->
                                    Util.(
                                      v |> member "Key" |> to_string |> extract_name,
                                      v |> member "Value" |> to_string |> Condo_utils.Base64.decode))) in
    match%map Async_http.(request_of_addr t.endpoint
                          |> path (Filename.concat "/v1/kv/" prefix')
                          |> query_param "recurse" ""
                          |> parser parse
                          |> get) with
    | Ok {Async_http.Response.body} ->
        Ok body
    | Error err ->
        Error (Exn.to_string err)
end

let consul ~endpoint ~prefix =
  let t = Consul.create ~endpoint ~prefix in
  (module struct
    let put ~key ~data = Consul.put t ~key ~data
    let get_all ?prefix () = Consul.get_all t ?prefix ()
  end : KV)
