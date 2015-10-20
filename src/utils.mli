open Core.Std
open Async.Std

module Deferred : sig
  val all_or_error : ('a, 'b) Result.t Deferred.t list -> ('a list, 'b) Result.t Deferred.t
end

val of_exn : Exn.t -> string
