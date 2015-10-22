open Core.Std
open Async.Std

type t

module Service : sig
  type id
  type name
  val of_string : string -> name
end

val create : string -> t

(* After stop it never produces new vals *)
val key : t -> string -> string Pipe.Reader.t * (unit -> unit Deferred.t)

(* After stop it never produces new discoveries *)
val discovery : t -> ?tag:string -> Service.name -> (string * int) list Pipe.Reader.t * (unit -> unit Deferred.t)

val register_service : t -> ?id_suffix:string -> Spec.Service.t -> int -> (Service.id, exn) Result.t Deferred.t

val deregister_service : t -> Service.id -> (unit, exn) Result.t Deferred.t

(* After stop it always returns Ok *)
val wait_for_passing : t -> (Service.id * Time.Span.t) list  -> ((unit, exn) Result.t Deferred.t * (unit -> unit Deferred.t))
