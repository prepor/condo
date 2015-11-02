module Result' = Result

open Core.Std
open Async.Std

module HTTP = Cohttp
module Server = Cohttp_async.Server

let hello_handler keys rest request =
  let who = Option.value (List.Assoc.find keys "who") ~default: "World" in
  sprintf "Hello, %s!" who |> return

let wait_handler keys rest request =
  "wait" |> return

(* let watch_handler keys rest request = *)
(*   let rec ticks w = *)
(*     print_endline "tick!"; *)
(*     printf "CLOSED?: %b" (Pipe.is_closed w); *)
(*     Pipe.write_when_ready w (fun writer -> writer "hello\n") >>= function *)
(*     | `Closed -> *)
(*       print_endline "CLOSE!"; *)
(*       return () *)
(*     | `Ok () -> *)
(*       after (Time.Span.of_ms 100.0) >>= fun () -> *)
(*       ticks w in *)
(*   let r = Pipe.init ticks in *)
(*   Server.respond_with_pipe r *)

let snapshot_handler monitoring _ _ _ =
  Monitoring.snapshot monitoring >>|
  Monitoring.snapshot_to_yojson >>|
  Yojson.Safe.to_string >>= fun data ->
  let headers = (Cohttp.Header.init_with "Content-Type" "application/json") in
  Server.respond_with_string ~headers data

let string_response handler keys rest request =
  (handler keys rest request) >>= Server.respond_with_string

let ui_response ui_path path =
  match ui_path with
  | Some ui_path -> Server.respond_with_file (ui_path ^ path)
  | None -> Server.respond_with_string "Hello from condo monitoring!"

let index_response ui_path _ _ _ =
  ui_response ui_path "/index.html"

let static_response ui_path _ tail request =
  match tail with
  | Some tail -> ui_response ui_path ("/" ^ tail)
  | None -> ui_response ui_path "/index.html"

let handler monitoring ui_path request =
  let table = [
    "/" , index_response ui_path
  ; "/static/*", static_response ui_path
  ; "/v1/wait", string_response wait_handler
  (* ; "/v1/sse/watch", watch_handler *)
  ; "/v1/snapshot", snapshot_handler monitoring
  ] in
  let uri = request.HTTP.Request.uri in
  match Dispatch.DSL.dispatch table (Uri.path uri) with
  | Result'.Ok handler -> handler request
  | Result'.Error _ -> Server.respond_with_string ~code:`Not_found "Not found"

let server port handler =
  let callback ~body _a req = handler req in
  let where_to_listen = Tcp.on_port port in
  Server.create where_to_listen callback |> Deferred.ignore

let create monitoring port ui_path =
  server port (handler monitoring ui_path)
