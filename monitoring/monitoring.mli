open Core.Std
open Async.Std

type t

module Instance : sig
  type t = {
    id : string;
    node : string;
    address : string;
    port : int;
    tags : string list;
    state : Yojson.Safe.json;
  }

  val to_yojson : t -> Yojson.Safe.json
end

type snapshot

val snapshot_to_yojson : snapshot -> Yojson.Safe.json

val create : Consul.t -> prefix:string -> tag:string option -> t

val snapshot : t -> snapshot Deferred.t
