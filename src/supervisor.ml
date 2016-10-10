open! Core.Std
open! Async.Std

type control = Stop | Suspend

module StringPool = Keyed_pool.Make(String)

type t = {
  workers : (unit, unit) Cancellable.t list;
  pool : Instance.t StringPool.t;
}

let file_extension path =
  Filename.basename path
  |> String.split ~on:'.'
  |> List.last_exn

let specs_list path =
  match%map try_with (fun () ->  Sys.readdir path) with
  | Ok v ->
      Array.to_list v
      |> List.filter_map ~f:(fun v ->
          if file_extension v = "edn" then Some (Filename.concat path v)
          else None)
  | Error err ->
      Logs.warn (fun m -> m "Can't read directory with specs %s: %s" path (Exn.to_string err));
      []

let watch_prefix system pool prefix =
  let tick () =
    let%bind specs = specs_list prefix in
    let%map () = StringPool.update pool specs in
    `Continue () in
  let wrapped () = Cancellable.defer_wait (tick ())in
  Cancellable.worker ~sleep:500 ~tick:wrapped ()

let create ~system ~prefixes =
  let on_new spec =
    let name = Utils.name_from_path spec in
    let snapshot = match System.get_snapshot system ~name with
    | None -> Instance.init_snaphot ()
    | Some v -> (match Instance.parse_snapshot v with
      | Ok v -> v
      | Error err ->
          Logs.warn (fun m -> m "Error while restoring snapshot for %s, initializing new one: %s" spec err);
          Instance.init_snaphot ()) in
    return @@ Instance.create system ~spec:spec ~snapshot in
  let pool = StringPool.create ~on_new ~on_stop:Instance.stop in
  let workers = List.map ~f:(watch_prefix system pool) prefixes in
  {workers;pool}

let stop' f t =
  let%bind () = Deferred.List.iter ~f:(fun v -> Cancellable.cancel v ()) t.workers in
  Deferred.List.iter ~f (StringPool.objects t.pool)

let stop = stop' Instance.stop

let suspend = stop' Instance.suspend
