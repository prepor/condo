open Core.Std
open Async.Std
open Cohttp
open Cohttp_async

module CA = Cohttp_async

type t = { endpoint: Uri.t }

type container = Id of string | Name of string

let container_to_string = function
  | Id v -> v
  | Name v -> v

let create endpoint = { endpoint = Uri.of_string endpoint }

let make_uri ?(query_params = []) t path =
  (Uri.with_path t.endpoint path |> Uri.with_query') query_params

(* let rename docker name = *)

let rm docker container = Error (Failure "foo") |> return

(* cmd := &createContainerCmd{ *)
(*    Host:    spec.Host, *)
(*    User:    spec.User, *)
(*    Image:   spec.Image.Id, *)
(*    Cmd:     spec.Cmd, *)
(*    Env:     envs, *)
(*    Volumes: volumes, *)
(*    HostConfig: hostConfig{ *)
(*      Binds:        binds, *)
(*      PortBindings: portBindings, *)
(*      Privileged:   spec.Privileged, *)
(*      NetworkMode:  spec.NetworkMode, *)
(*      LogConfig:    logs, *)
(*    }, *)
(*  } *)

let pull_image t image =
  let is_error line =
    let open Yojson.Basic.Util in
    let parse () = Yojson.Basic.from_string body |> member "Error" |> to_string_option in
    try Ok (parse () |> function
      | Some error_str -> Error (Failure error_str)
      | None -> Ok ())
    with exc -> Error (Failure "Parsing failed") in
  (* let error_checker r = *)

  (* let params = Spec.Image.([("fromImage", image.name); ("tag", image.tag)]) in *)
  (* let uri = make_uri t ~query_params:params "/images/create" in *)
  (* let do_req () = Client.post uri in *)
  (* try_with do_req >>=? Utils.HTTP.not_200_as_error >>=? fun (resp, body) -> *)
  (* CA.Body.to_pipe body |> Utils.Pipe.to_lines |> fun lines -> *)
  return (Failure "ok")

let start t spec =
  Error (Failure "foo") |> return

let stop docker container = Error (Failure "foo") |> return
