open! Async.Std
type t

val create :
  docker_endpoint:Async_http.addr ->
  docker_config:string option ->
  state_path:string ->
  t Deferred.t

val docker : t -> Docker.t

val place_snapshot : t -> name:string -> snapshot:Yojson.Safe.json -> unit Deferred.t

val get_snapshot : t -> name:string -> Yojson.Safe.json option

(* For tests only *)
type state = (string * Yojson.Safe.json) list [@@deriving yojson]
