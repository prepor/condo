open! Core.Std
open! Async.Std

type state = (string * Yojson.Safe.json) list [@@deriving yojson]

type t = {
  docker : Condo_docker.t;
  state_path : string;
  kv : (module Condo_kv.KV) option;
  mutable state : state;
}

let read_state state_path =
  match%map try_with (fun () -> Reader.file_contents state_path
                       >>| Yojson.Safe.from_string) with
  | Ok `Assoc l -> l
  | Ok _ | Error _ ->
      Logs.app (fun m -> m "Can't read state file, initialized the new one");
      []

let create ~docker_endpoint ~docker_config ~state_path ~expose_state =
  let%bind docker = Condo_docker.create ~endpoint:docker_endpoint ~config_path:docker_config in
  let%map state = read_state state_path in
  let kv = match expose_state with
  | `No -> None
  | `Consul (endpoint, prefix) -> Some (Condo_kv.consul ~endpoint ~prefix) in
  {docker; state_path; state; kv}

let docker {docker} = docker

let place_snapshot t ~name ~snapshot =
  t.state <- List.Assoc.add t.state name snapshot;
  let contents = Yojson.Safe.to_string @@ `Assoc t.state in
  let%map () = Writer.save ~fsync:true t.state_path ~contents in
  match t.kv with
  | Some kv -> let module KV = (val kv : Condo_kv.KV) in
      KV.put ~key:name ~data:(Yojson.Safe.to_string snapshot)
  | None -> ()

let get_snapshot t ~name =
  List.Assoc.find t.state name

let get_state t = t.state

let get_global_state ?prefix t =
  let get_global_state' kv =
    let module KV = (val kv : Condo_kv.KV) in
    match%map (KV.get_all ?prefix ()) with
    | Ok res -> Ok (List.Assoc.map res ~f:Yojson.Safe.from_string)
    | Error err -> Error err in
  match t.kv with
  | Some v -> get_global_state' v >>| (fun v -> Some v)
  | None -> return None
