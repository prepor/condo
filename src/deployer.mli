open Async.Std

type t

val create : Consul.t -> Docker.t -> t

val start : t -> string -> (unit -> unit Deferred.t)
