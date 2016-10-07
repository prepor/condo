open! Core.Std
open! Async.Std

type state = (string * Sexp.t) list [@@deriving sexp]

type t = {
  docker : Docker.t;
  prefixes : string list;
  state_path : string;
  mutable state : state;
}

let read_state state_path =
  match%map try_with (fun () -> Reader.file_contents state_path >>| Sexp.of_string >>| state_of_sexp) with
  | Ok v -> v
  | Error e ->
      Logs.info (fun m -> m "Can't read state file, initialized new one");
      []

let create ~docker_endpoint ~docker_config ~prefixes ~state_path =
  let%bind docker = Docker.create ~endpoint:docker_endpoint ~config_path:docker_config in
  let%map state = read_state state_path in
  {docker; prefixes; state_path; state}

let docker {docker} = docker

let place_snapshot t ~name ~snapshot =
  t.state <- List.Assoc.add t.state name snapshot;
  Writer.save ~fsync:true t.state_path ~contents:(t.state |> sexp_of_state |> Sexp.to_string_hum)
