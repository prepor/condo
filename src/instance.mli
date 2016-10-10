open! Core.Std
open! Async.Std

type t

type container = {
  id : Docker.id;
  spec : Spec.t
} [@@deriving sexp]

type snapshot = | Init
                | Wait of container
                | TryAgain of (Spec.t * float)
                | Stable of container
                | WaitNext of (container * container)
                | TryAgainNext of (container * Spec.t * float)
[@@deriving sexp, yojson]

val parse_snapshot : Yojson.Safe.json -> (snapshot, string) Result.t

val init_snaphot : unit -> snapshot

val create : System.t -> spec:string -> snapshot:snapshot -> t

val suspend : t -> unit Deferred.t

val stop : t -> unit Deferred.t
