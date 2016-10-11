open! Core.Std
open! Async.Std

type state = (string * Yojson.Safe.json) list [@@deriving yojson]

type t = {
  docker : Condo_docker.t;
  state_path : string;
  mutable state : state;
}

let read_state state_path =
  match%map try_with (fun () -> Reader.file_contents state_path
                       >>| Yojson.Safe.from_string
                       >>| state_of_yojson
                       >>| Result.ok_or_failwith) with
  | Ok v -> v
  | Error e ->
      Logs.app (fun m -> m "Can't read state file, initialized the new one");
      []

let create ~docker_endpoint ~docker_config ~state_path =
  let%bind docker = Condo_docker.create ~endpoint:docker_endpoint ~config_path:docker_config in
  let%map state = read_state state_path in
  {docker; state_path; state}

let docker {docker} = docker

let place_snapshot t ~name ~snapshot =
  t.state <- List.Assoc.add t.state name snapshot;
  Writer.save ~fsync:true t.state_path ~contents:(t.state |> state_to_yojson |> Yojson.Safe.to_string)

let get_snapshot t ~name =
  List.Assoc.find t.state name
