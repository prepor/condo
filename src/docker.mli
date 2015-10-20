open Async.Std
open Core.Std

type t

type container = Id of string | Name of string

val container_to_string : container -> string

val create : string -> t

val start : t -> Spec.t -> (container, exn) Result.t Deferred.t

val stop : t -> container -> (unit, exn) Result.t Deferred.t

val rm : t -> container -> (unit, exn) Result.t Deferred.t
