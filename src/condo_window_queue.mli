open! Async.Std

type 'a t

val create : size:int -> 'a t

val read : 'a t -> 'a Deferred.t

val write : 'a t -> 'a -> unit
