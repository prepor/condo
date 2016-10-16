open! Core.Std
open! Async.Std
type t

val create :
  docker_endpoint: Async_http.addr ->
  docker_config: string option ->
  state_path: string ->
  expose_state: [`No | `Consul of (Async_http.addr * string)] ->
  host: string option ->
  t Deferred.t

val docker : t -> Condo_docker.t

val place_snapshot : t -> name:string -> snapshot:Yojson.Safe.json -> unit Deferred.t

val get_snapshot : t -> name:string -> Yojson.Safe.json option

type state = (string * Yojson.Safe.json) list [@@deriving yojson]

val get_state : t -> state

type meta = { host : string } [@@deriving yojson]

type global_data = {
  snapshot : Yojson.Safe.json;
  meta : meta
} [@@deriving yojson]

type global_state = (string * global_data) list [@@deriving yojson]

val get_global_state : ?prefix:string -> t -> (global_state, string) Result.t option Deferred.t


