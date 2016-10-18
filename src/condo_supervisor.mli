open! Core.Std
open! Async.Std

type t

val create : system:Condo_system.t -> prefixes:string list -> t

val stop : t -> unit Deferred.t

val suspend : t -> unit Deferred.t
