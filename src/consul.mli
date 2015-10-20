open Core.Std
open Async.Std

type t

module Service : sig
  type id
  type name
  val of_string : string -> name
end

val create : string -> t

val key : t -> string -> string Pipe.Reader.t * (unit -> unit Deferred.t)

val discovery : t -> ?tag:string -> Service.name -> (string * int) list Pipe.Reader.t * (unit -> unit Deferred.t)

val register_service : t -> ?id_suffix:string -> Spec.service -> (Service.id, exn) Result.t Deferred.t

val deregister_service : t -> Service.id -> (unit, exn) Result.t Deferred.t

val wait_for_passing : t -> (Service.id * Time.Span.t) list  -> ((unit, exn) Result.t Deferred.t * (unit -> unit Deferred.t))
