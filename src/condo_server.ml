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

let receive_state ?prefix system =
  match%map System.get_global_state ?prefix system with
  | Some Ok state -> Ok state
  | Some Error err ->
      Logs.err (fun m -> m "Error in get_global_state method: %s" err);
      Error (error_response ~status:`Internal_server_error err)
  | None -> Error (error_response ~status:`Bad_request "State exposing is not configured")

let get_global_state system =
  match%map receive_state system with
  | Ok state -> json_response (`List (List.map state ~f:(fun (k,v) -> `List [`String k; v])))
  | Error err -> err

let wait_for' system ~image ~name ~timeout =
  let module Cancel = Cancellable in
  let image_from_container container =
    let open Yojson.Basic.Util in
    container.Condo_instance.spec.Condo_spec.spec
    |> member "Image" |> to_string_option in
  let stable_image_from_snapshot snapshot =
    let open Condo_instance in
    match snapshot with
    | Stable container -> image_from_container container
    | _ -> None in
  let find_in_state state =
    let f (name', instance_state) =
      if name <> name' then false
      else (match Condo_instance.parse_snapshot instance_state with
        | Error err ->
            Logs.err (fun m -> m "Error while parsing instance state %s: %s" name' err);
            false
        | Ok snapshot ->
            (match stable_image_from_snapshot snapshot with
            | Some image' -> image = image'
            | None -> false)) in
    match List.find state ~f with
    | Some _ -> true
    | None -> false in
  let tick () = match%map receive_state ~prefix:name system with
  | Ok state -> (match find_in_state state with
    | true -> `Complete ()
    | false -> `Continue ())
  | Error err -> `Continue () in
  Cancel.(
    let passing_waiter = worker ~sleep:1000 ~tick:(Cancel.wrap_tick tick) () in
    let timeout = after (Time.Span.of_int_sec timeout) |> defer in
    choose [
      passing_waiter --> (fun () -> json_response (`Assoc ["status", `String "ok"]));
      timeout --> (fun () -> json_response ~status:`Not_found (`Assoc ["status", `String "error"]));
    ])

let string_param ~param params =
  let open Result in
  try_with (fun () -> List.Assoc.find_exn params param |> List.hd_exn)
  |> map_error ~f:(fun _ -> (sprintf "%s param is required" param))

let int_param ~param params =
  let open Result in
  try_with (fun () -> List.Assoc.find_exn params param |> List.hd_exn |> int_of_string)
  |> map_error ~f:(fun _ -> (sprintf "%s param is required and should be integer" param))

let wait_for system request =
  let params = Request.uri request |> Uri.query in
  (let open Result.Let_syntax in
   let%bind name = string_param "name" params in
   let%bind image = string_param "image" params in
   let%map timeout = int_param "timeout" params in
   wait_for' system ~image ~name ~timeout) |> function
  | Error err -> return @@ error_response ~status:`Bad_request err
  | Ok v -> v

let handler system ~body addr request =
  match Request.uri request |> Uri.path with
  | "/" -> (Response.make (), Body.of_string "Hello world!") |> return
  | "/v1/state" -> get_self_state system
  | "/v1/global_state" -> get_global_state system
  | "/v1/wait_for" -> wait_for system request
  | _ -> error_response ~status:`Not_found "Not found" |> return

let create system ~port =
  let%map _ = Server.create ~on_handler_error:(`Call error_handler ) (Tcp.on_port port) (handler system) in
  ()
