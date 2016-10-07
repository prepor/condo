open! Core.Std
open! Async.Std

type ('a, 'b) t

val create : 'a Deferred.t -> canceller:('b -> unit Deferred.t) -> ('a, 'b) t

(* Pass cancelling event as deferred to function. it becomes determined on
   cancel event. Such cancellables always return `Result on wait *)
val wrap : ('b Deferred.t -> 'a Deferred.t) -> ('a, 'b) t

val wait : ('a, 'b) t -> [`Result of 'a | `Cancelled of 'b] Deferred.t

val cancel : ('a, 'b) t -> 'b -> unit Deferred.t

(* Creates cancellable from any deferred. On cancel don't wait anything *)
val defer : 'a Deferred.t -> ('a, 'b) t
(* Creates cancellable from any deferred. On cancel wait for underling deferred. Always returns `Result on wait as wrap-cancellable *)
val defer_wait : 'a Deferred.t -> ('a, 'b) t

(* Cancellable worker loop. Constantly call `tick` until canceling. Cancelling cancel current tick too *)
val worker : ?timeout:int -> tick:('b -> ([`Complete of 'a | `Continue of 'b], 'c) t) -> 'b -> ('a, 'c) t

type 'a choice = Choice : ('c, unit) t * ('c -> 'a) -> 'a choice

val choice : ('c, unit) t -> ('c -> 'a) -> 'a choice
val (-->) : ('c, unit) t -> ('c -> 'a) -> 'a choice

(* TODO cancelable variant of choose *)
val choose : 'a choice list -> 'a Deferred.t

include Monad.S2 with type ('a, 'b) t := ('a, 'b) t
