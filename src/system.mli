open! Async.Std
type t

val create :
  docker_endpoint:Async_http.addr ->
  docker_config:string option ->
  prefixes:string list ->
  state_path:string ->
  t Deferred.t

val docker : t -> Docker.t

val place_snapshot : t -> name:string -> snapshot:Sexp.t -> unit Deferred.t
