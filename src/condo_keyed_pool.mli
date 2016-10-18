open! Core.Std
open! Async.Std

module type S = sig
  type key
  type 'a t

  val create : on_new:(key -> 'a option Deferred.t) -> on_stop:('a -> unit Deferred.t) -> 'a t

  val update : 'a t -> key list -> unit Deferred.t

  val objects : 'a t -> 'a list
end

module Make (Key : Map.Key) : S with type key = Key.t
