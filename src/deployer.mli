open Async.Std

type t

val create : Consul.t -> Docker.t -> string -> t

val start : t -> string -> (unit -> unit Deferred.t)
