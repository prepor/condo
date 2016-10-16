open! Core.Std
open! Async.Std

type t

type container = {
  id : Condo_docker.id;
  spec : Condo_spec.t;
  created_at : float;
  stable_at : float option;
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

val create : Condo_system.t -> spec:string -> snapshot:snapshot -> t

val suspend : t -> unit Deferred.t

val stop : t -> unit Deferred.t
