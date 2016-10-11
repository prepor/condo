open! Core.Std
open! Async.Std

module Server = Cohttp_async.Server
module Request = Cohttp_async.Request
module Response = Cohttp_async.Response
module Body = Cohttp_async.Body
module Header = Cohttp.Header

module System = Condo_system

type t = unit

let error_handler addr exn =
  Logs.warn (fun m -> m "Error while http request handling: %s" (Exn.to_string exn))

let error_response ?status s =
  Response.make ?status (), Body.of_string s

let json_response ?status json =
  let body = json |> Yojson.Safe.to_string |> Body.of_string in
  let headers = Header.init_with "Content-Type" "application/json" in
  (Response.make ?status ~headers (), body)

let get_self_state system =
  return @@ json_response (`Assoc (System.get_state system))

let get_global_state system =
  match%map System.get_global_state system with
  | Some Ok state -> json_response (`Assoc state)
  | Some Error err ->
      Logs.err (fun m -> m "Error in get_global_state method: %s" err);
      error_response ~status:`Internal_server_error err
  | None -> error_response ~status:`Bad_request "State exposing is not configured"

(* let wait_for *)

let handler system ~body addr request =
  match Request.uri request |> Uri.path with
  | "/" -> (Response.make (), Body.of_string "Hello world!") |> return
  | "/v1/state" -> get_self_state system
  | "/v1/global_state" -> get_global_state system
  | _ -> error_response ~status:`Not_found "Not found" |> return

let create system ~port =
  let%map _ = Server.create ~on_handler_error:(`Call error_handler ) (Tcp.on_port port) (handler system) in
  ()
