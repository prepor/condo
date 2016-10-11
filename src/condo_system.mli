open! Core.Std
open! Async.Std
type t

val create :
  docker_endpoint: Async_http.addr ->
  docker_config: string option ->
  state_path: string ->
  expose_state: [`No | `Consul of (Async_http.addr * string)] ->
  t Deferred.t

val docker : t -> Condo_docker.t

val place_snapshot : t -> name:string -> snapshot:Yojson.Safe.json -> unit Deferred.t

val get_snapshot : t -> name:string -> Yojson.Safe.json option

type state = (string * Yojson.Safe.json) list [@@deriving yojson]

val get_state : t -> state

val get_global_state : ?prefix:string -> t -> (state, string) Result.t option Deferred.t 


