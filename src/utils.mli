open Core.Std
open Async.Std

module Deferred : sig
  val all_or_error : ('a, 'b) Result.t Deferred.t list -> ('a list, 'b) Result.t Deferred.t
end

module HTTP : sig
  val not_200_as_error :
    Cohttp_async.Response.t * Cohttp_async.Body.t -> (Cohttp_async.Response.t * Cohttp_async.Body.t, exn) Result.t Async.Std.Deferred.t

  type http_method = Get | Post | Delete | Put
  val simple : ?req:http_method -> ?body:string -> ?headers:Cohttp.Header.t ->
    parser:(Yojson.Basic.json -> 'a) -> Uri.t -> ('a, exn) Result.t Async.Std.Deferred.t
end

module Pipe : sig
  val to_lines : string Pipe.Reader.t -> string Pipe.Reader.t

  val dummy_reader : 'a Pipe.Reader.t -> unit Async.Std.Deferred.t
end

module Assoc : sig
  val merge : ('a, 'b) List.Assoc.t -> ('a, 'b) List.Assoc.t -> ('a, 'b) List.Assoc.t
end

module RunMonitor : sig
  type t

  val create : unit -> t

  val completed : t -> unit

  val is_running : t -> bool

  val close : t -> unit Async.Std.Deferred.t

  val closer : t -> (unit -> unit Async.Std.Deferred.t)
end

val of_exn : Exn.t -> string

val random_str : int -> string

val exn_to_string : exn -> string
