open! Core.Std
open! Async.Std

type control = Stop | Suspend

module StringPool = Condo_keyed_pool.Make(String)
module Instance = Condo_instance
module Cancel = Condo_cancellable

type t = {
  workers : (unit, unit) Cancel.t list;
  pool : Instance.t StringPool.t;
  mutable status : [`Started | `Stopped];
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
  Cancel.worker ~sleep:500 ~tick:(Cancel.wrap_tick tick) ()

let stop' f t =
  if t.status = `Stopped then return ()
  else begin
    t.status <- `Stopped;
    let%bind () = Deferred.List.iter ~f:(fun v -> Cancel.cancel v ()) t.workers in
    Deferred.List.iter ~f (StringPool.objects t.pool)
  end

let stop = stop' Instance.stop

let suspend = stop' Instance.suspend

let create ~system ~prefixes =
  let self = ref None in
  let on_new spec =
    let name = Condo_utils.name_from_path spec in
    let snapshot = match Condo_system.get_snapshot system ~name with
    | None -> Instance.init_snaphot ()
    | Some v -> (match Instance.parse_snapshot v with
      | Ok v -> v
      | Error err ->
          Logs.warn (fun m -> m "Error while restoring snapshot for %s, initializing new one: %s" spec err);
          Instance.init_snaphot ()) in
    let%map on_stable = if name = "self" then begin
        Logs.app (fun m -> m "New version of self found, deploy started");
        let%map () = suspend (Option.value_exn !self) in
        Some (fun snapshot ->
            let%map () = Condo_system.place_snapshot system ~name
                ~snapshot:(Instance.snapshot_to_yojson snapshot) in
            Shutdown.shutdown 0)
      end
      else return None in
    Instance.create system ~spec:spec ?on_stable ~snapshot in
  let pool = StringPool.create ~on_new ~on_stop:Instance.stop in
  let workers = List.map ~f:(watch_prefix system pool) prefixes in
  let t = {workers;pool;status = `Started} in
  self := Some t;
  t
