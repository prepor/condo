open Core.Std
open Async.Std

module Instance = struct
  type t = {
    id : string;
    node : string;
    address : string;
    port : int;
    tags : string list;
    state : Yojson.Safe.json;
  } [@@deriving yojson]
end

module PairMap = struct
  module T = struct
    type t = (string * string) [@@deriving sexp, compare]
  end
  include Map.Make(T)

  let remove_by_prefix t prefix =
    List.fold (keys t) ~init:t ~f:(fun t (k1, k2) ->
        if k1 = prefix then
          remove t (k1, k2)
        else
          t)
end

type snapshot = Instance.t PairMap.t

let snapshot_to_yojson snapshot =
  let res =
    PairMap.map snapshot Instance.to_yojson
    |> PairMap.to_alist
    |> List.map ~f:(fun ((prefix, k), v) -> (k, v)) in
  `Assoc res

module Watcher = struct
  type event = Services of Consul.CatalogService.t String.Map.t
             | KeyValue of Consul.CatalogService.t * string * string
             | KeyRemoved of Consul.CatalogService.t * string
             | Snapshot of snapshot Ivar.t

  type t =
    { consul : Consul.t;
      keys_prefix : string;
      snapshot : snapshot;
      services: (string, (unit -> unit Deferred.t)) List.Assoc.t;
      control_r : event Pipe.Reader.t;
      control_w : event Pipe.Writer.t; }

  let diff services consul_services =
    let current_keys = services |> List.map ~f:fst |> String.Set.of_list in
    let current'_keys = consul_services |> String.Set.of_map_keys in
    let new_services = String.Set.diff current'_keys current_keys |> String.Set.to_list in
    let removed_services = String.Set.diff current_keys current'_keys |> String.Set.to_list in
    (List.map new_services (String.Map.find_exn consul_services),
     removed_services)

  let apply_services t services =
    let (new_, removed) = diff t.services services in
    let services' = List.fold new_ ~init:t.services ~f:(fun accum s ->
        let id = s.Consul.CatalogService.id in
        let (values, stopper) = Consul.prefix t.consul (sprintf "%s/%s" t.keys_prefix id) in
        Pipe.iter values (function
            | `New {Consul.KvBody.value; key} -> Pipe.write t.control_w (KeyValue (s, key, value))
            | `Updated {Consul.KvBody.value; key} -> Pipe.write t.control_w (KeyValue (s, key, value))
            | `Removed key -> Pipe.write t.control_w (KeyRemoved (s, key))) |> don't_wait_for;
        (id, stopper)::accum) in
    let snapshot' = List.fold removed ~init:t.snapshot ~f:PairMap.remove_by_prefix in
    let services'' = List.fold removed ~init:services' ~f:(fun accum service ->
        let stopper = List.Assoc.find_exn t.services service in
        stopper () |> don't_wait_for;
        List.Assoc.remove accum service) in
    { t with services = services'';
             snapshot = snapshot'}

  let make_instance service state =
    let {Consul.CatalogService.id; address; node; port; tags} = service in
    { Instance.id; address; node; port; tags;
      state = state;}

  let apply_key_value t service key value =
    let {Consul.CatalogService.id} = service in
    Result.try_with (fun () -> Yojson.Safe.from_string value) |> function
    | Error err ->
      L.error "Error while reading state json for service %s: %s" key (Exn.to_string err);
      t
    | Ok state ->
      let instance' = make_instance service state in
      let snapshot' = PairMap.add t.snapshot ~key:(id, key) ~data:instance' in
      { t with snapshot = snapshot' }

  let apply_key_removed t service key =
    let {Consul.CatalogService.id} = service in
    let snapshot' = PairMap.remove t.snapshot (id, key) in
    { t with snapshot = snapshot' }

  let apply_snapshot t answer =
    Ivar.fill answer t.snapshot;
    t

  let apply t = function
    | Services consul_services -> apply_services t consul_services
    | KeyValue (consul_service, key, value) -> apply_key_value t consul_service key value
    | KeyRemoved (consul_service, key) -> apply_key_removed t consul_service key
    | Snapshot answer -> apply_snapshot t answer

  let loop t =
    let rec tick t =
      Pipe.read t.control_r >>= function
      | `Ok v -> apply t v |> tick
      | `Eof -> assert false in
    tick t

  let start consul keys_prefix =
    let (services, _closer) = Consul.catalog_service consul "condo" in
    let (control_r, control_w) = Pipe.create () in
    let t = { consul; keys_prefix;
              control_r; control_w;
              snapshot = PairMap.empty;
              services = []; } in
    Pipe.transfer services control_w ~f:(fun v -> Services (String.Map.of_alist_exn v)) |> don't_wait_for;
    loop t |> don't_wait_for;
    t

end

type t = Watcher.t

let snapshot t =
  let res = Ivar.create () in
  Pipe.write t.Watcher.control_w (Watcher.Snapshot res) >>= fun () ->
  Ivar.read res

let create consul ~prefix ~tag =
  let watcher = Watcher.start consul prefix in
  watcher
