open! Core.Std
open! Async.Std

type t

type container = {
  id : Condo_docker.id;
  spec : Condo_spec.t
} [@@deriving sexp]

type snapshot = | Init
                | Wait of container
                | TryAgain of (Condo_spec.t * float)
                | Stable of container
                | WaitNext of (container * container)
                | TryAgainNext of (container * Condo_spec.t * float)
[@@deriving sexp, yojson]

val parse_snapshot : Yojson.Safe.json -> (snapshot, string) Result.t

val init_snaphot : unit -> snapshot

val create : ?on_stable:(snapshot -> unit Deferred.t) -> Condo_system.t -> spec:string -> snapshot:snapshot -> t

val suspend : t -> unit Deferred.t

val stop : t -> unit Deferred.t
