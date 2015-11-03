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

type snapshot = Instance.t String.Map.t

val snapshot_to_yojson : snapshot -> Yojson.Safe.json

type change = Add of Instance.t | Remove of string | Update of Instance.t

type signal = change * snapshot

val create : Consul.t -> prefix:string -> tag:string option -> t

val snapshot : t -> snapshot Deferred.t

val subscribe : t -> signal Pipe.Reader.t Deferred.t

val unsubscribe : t -> signal Pipe.Reader.t -> unit Deferred.t
