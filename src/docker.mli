open! Core.Std
open! Async.Std

type t
type id [@@deriving sexp]

val create : endpoint:Async_http.addr -> config_path:string option -> t Deferred.t

val reload_config : t -> unit Deferred.t

val start : t -> name:string -> spec:Edn.t -> (id, string) Result.t Deferred.t

val stop : t -> id -> timeout:int -> unit Deferred.t

val wait_healthchecks : t -> id -> timeout:int -> [`Passed | `Not_passed] Deferred.t
