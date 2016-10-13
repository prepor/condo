open! Core.Std
open! Async.Std

module type S = sig
  type key
  type 'a t

  val create : on_new:(key -> 'a option Deferred.t) -> on_stop:('a -> unit Deferred.t) -> 'a t

  val update : 'a t -> key list -> unit Deferred.t

  val objects : 'a t -> 'a list
end

module Make (Key : Map.Key) = struct
  type key = Key.t

  module KeyMap = Map.Make(Key)
  module KeySet = Set.Make(Key)
  type 'a t = {
    mutable objects : 'a KeyMap.t;
    on_new : key -> 'a option Deferred.t;
    on_stop : 'a -> unit Deferred.t;
  }

  let create ~on_new ~on_stop =
    {objects = KeyMap.empty; on_new; on_stop}

  let update t l =
    let keys = Map.keys t.objects in
    let new_keys = Set.diff (KeySet.of_list l) (KeySet.of_list keys) |> Set.to_list in
    let removed_keys = Set.diff (KeySet.of_list keys) (KeySet.of_list l) |> Set.to_list in
    let%bind new_objects = Deferred.List.filter_map new_keys ~f:(fun k -> match%map t.on_new k with
      | Some v -> Some (k, v)
      | None -> None) in
    let removed_objects = List.map removed_keys ~f:(fun k -> Map.find_exn t.objects k) in
    let%map () = Deferred.List.iter removed_objects ~f:t.on_stop in
    let objects' = List.fold_left new_objects
        ~init:t.objects
        ~f:(fun m (key, data) -> KeyMap.add m ~key ~data) in
    let objects'' = List.fold_left removed_keys ~init:objects' ~f:KeyMap.remove in
    t.objects <- objects''

  let objects t = KeyMap.data t.objects
end
