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

module SelfInstance = struct
  let need_to_start spec =
    let hash = Digest.string spec |> Digest.to_hex in
    match Sys.getenv "CONDO_SELF" with
    | Some v when v = hash -> false
    | _ -> true

  let start system spec =
    let inject_hash = function
    | `Assoc l ->
        let envs = match List.Assoc.find l "Env" with
        | Some `List envs -> envs
        | None -> []
        | _ -> failwith "Bad formatted Env in self spec" in
        let hash = Digest.string spec |> Digest.to_hex in
        let envs' = `List (`String (sprintf "CONDO_SELF=%s" hash)::envs) in
        `Assoc (List.Assoc.add l "Env" envs')
    | _ -> failwith "Bad formatted self spec" in
    match Result.try_with (fun () -> Yojson.Basic.from_string spec) with
    | Error err ->
        Logs.err (fun m -> m "Can't parse self spec: %s" (Exn.to_string err));
        Shutdown.shutdown 1;
        return ()
    | Ok spec ->
        let docker = Condo_system.docker system in
        match%bind Condo_docker.start docker ~name:"condo" ~spec:(inject_hash spec) with
        | Error err ->
            Logs.err (fun m -> m "Can't start myself: %s" err);
            Shutdown.shutdown 1;
            return ()
        | Ok id ->
            match%map Condo_docker.wait_healthchecks docker id ~timeout:10 with
            | `Not_passed ->
                Logs.err (fun m -> m "Health checks of myself haven't passed ;(");
                Shutdown.shutdown 1;
                ()
            | `Passed ->
                Logs.app (fun m -> m "Successfully deployed myself as %s" (Sexp.to_string_hum @@ Condo_docker.sexp_of_id id));
                Shutdown.shutdown 0
end

let create ~system ~prefixes =
  let self = ref None in
  let on_new spec =
    let name = Condo_utils.name_from_path spec in
    if name = "self" && SelfInstance.need_to_start spec then begin
      Logs.app (fun m -> m "New version of self found, deploy started");
      let%map () = suspend (Option.value_exn !self) in
      SelfInstance.start system spec |> don't_wait_for;
      None end
    else begin
      let snapshot = match Condo_system.get_snapshot system ~name with
      | None -> Instance.init_snaphot ()
      | Some v -> (match Instance.parse_snapshot v with
        | Ok v -> v
        | Error err ->
            Logs.warn (fun m -> m "Error while restoring snapshot for %s, initializing new one: %s" spec err);
            Instance.init_snaphot ()) in
      return @@ Some (Instance.create system ~spec:spec ~snapshot)
    end in
  let pool = StringPool.create ~on_new ~on_stop:Instance.stop in
  let workers = List.map ~f:(watch_prefix system pool) prefixes in
  let t = {workers;pool;status = `Started} in
  self := Some t;
  t
