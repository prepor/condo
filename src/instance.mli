open! Core.Std
open! Async.Std

type t
type snapshot [@@deriving sexp]

val parse_snapshot : Sexp.t -> (snapshot, string) Result.t

val init_snaphot : unit -> snapshot

val create : System.t -> spec:string -> snapshot:snapshot -> t

val suspend : t -> unit Deferred.t

val stop : t -> unit Deferred.t
