open Core.Std
open Async.Std

module Deferred : sig
  val all_or_error : ('a, 'b) Result.t Deferred.t list -> ('a list, 'b) Result.t Deferred.t
end

module HTTP : sig
  val not_200_as_error :
    Cohttp_async.Response.t * Cohttp_async.Body.t -> (Cohttp_async.Response.t * Cohttp_async.Body.t, exn) Result.t Async.Std.Deferred.t
end

module Pipe : sig
  val to_lines : string Pipe.Reader.t -> string Pipe.Reader.t
end

val of_exn : Exn.t -> string
