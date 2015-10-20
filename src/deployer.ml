open Core.Std
open Async.Std

type deploy = {
  spec: Spec.t;
  container: Docker.container;
  services: (Spec.service * Consul.Service.id) list;
  stop_checks: (unit -> unit Deferred.t);
  stop_discoveries: (unit -> unit Deferred.t);
  stable: bool;
  created_at: float;
  stable_at: float option;
}

type state = {
  current: deploy option;
  next: deploy option;
  last_stable: Spec.t option;
}

type change = NewSpec of Spec.t
            | NewDiscovery of Spec.discovery * (string * int) list
            | NowStable of Docker.container
            | NotStable of Docker.container
            | TryAgain of Spec.t

type t = {
  changes: change Pipe.Reader.t;
  changes_w: change Pipe.Writer.t;
  docker: Docker.t;
  consul: Consul.t;
}

(* We just ignore fails in stop action *)
let stop t = function
  | Some deploy ->
    let r = deploy.stop_checks () >>= fun _ ->
      deploy.stop_discoveries () >>= fun _ ->
      Docker.stop t.docker deploy.container >>=? fun _ ->
      Docker.rm t.docker deploy.container in
    r >>= (function
        | Error err ->
          print_endline ("Error in stopping" ^ (Utils.of_exn err));
          return ()
        | Ok _ -> return ())
  | None -> return ()

let stop_if_needed t state stop_before =
  let stop_next_if_need state =
    stop t state.next >>= fun _ ->
    return { state with next = None } in
  let stop_current_if_need state = match (state.current, stop_before) with
    | (Some deploy, true) -> stop t state.current >>= fun _ ->
      return { state with next = None }
    | _ -> return state in
  stop_next_if_need state >>= stop_current_if_need

let stable_watcher t container services =
  let wait_for = List.map services (fun (spec, id) -> (id, Spec.(Time.Span.of_int_sec spec.check.timeout))) in
  let (waiter, closer) = Consul.wait_for_passing t.consul wait_for in
  let stable_watcher' = waiter >>= function
    | Ok _ -> Pipe.write t.changes_w (NowStable container)
    | Error _ -> Pipe.write t.changes_w (NotStable container) in
  stable_watcher' |> don't_wait_for;

  closer

let partition_result l = List.partition_map l ~f: (function
    | Ok v -> `Fst v
    | Error v -> `Snd v)

let discovery_to_env spec v =
  let open Spec in
  let format_pair = (fun (host, port) -> sprintf "%s:%i" host port ) in
  let mk_env v = { value = v;
                   name = spec.env; } in
  match (v, spec.multiple) with
  | (v, true) -> List.map v ~f: format_pair |> String.concat ~sep:"," |> mk_env
  | (x::xs, false) -> format_pair x |> mk_env
  | ([], false) -> failwith "Empty discovery result"

let schedule_try_again t spec =
  after (Time.Span.of_int_sec 5) >>= (fun _ ->
      Pipe.write t.changes_w (TryAgain spec))
  |> don't_wait_for

(* It resolves first value of each required discovery and starts watcher for
   each of discoveries. Returns resolved first values and stop-function for loop *)
let discoveries_watcher t spec =
  let discovery_watcher d_spec r =
    Pipe.iter r ~f: (fun v -> Pipe.write t.changes_w (NewDiscovery (d_spec, v)) ) in
  let discoveries' = List.map spec.Spec.discoveries ~f: (fun spec ->
      (spec, Consul.discovery t.consul ?tag:spec.Spec.tag (Consul.Service.of_string spec.Spec.service))) in
  let init_services = List.map discoveries' ~f: (fun (spec, (r, _)) ->
      Pipe.read r >>| (function
          | `Eof -> Error ("Can't receive discovery for " ^ spec.Spec.service)
          | `Ok v -> Ok (spec, v)))
                      |> Deferred.all >>| partition_result in
  with_timeout (Time.Span.of_int_sec 10) init_services >>= function
  | `Timeout ->
    print_endline "Timeout while resolving discoveries";
    schedule_try_again t spec;
    Error (Failure "Cant resolve discoveries") |> return
  | `Result (init_discoveries, fails) ->
    if (List.length fails) > 0 then Error (Failure "Discoveries failed") |> return
    else
      (List.iter discoveries' ~f: (fun (spec, (r, _)) -> discovery_watcher spec r |> ignore);
       (let vals = List.map init_discoveries ~f: (Tuple.T2.uncurry discovery_to_env) in
        return (Ok (vals, (fun _ -> (List.map discoveries' ~f: (fun (_, (_, stopper)) -> stopper ()))
                                    |> Deferred.all >>| (fun _ -> ()))))))

let now () = let open Core.Time in now () |> to_epoch

let register_services t spec container =
  let suffix = Docker.container_to_string container in
  let register_service service_spec =
    Consul.register_service t.consul ~id_suffix:suffix service_spec >>|?
    fun service_id -> (service_spec, service_id) in
  List.map spec.Spec.services register_service |> Deferred.all >>|
  partition_result >>| fun (res, errors) ->
  let service_ids = List.map res snd in
  let close_registered () =
    List.map service_ids (Consul.deregister_service t.consul) |> Deferred.all >>| fun _ -> () in
  match errors with
  | x::_ -> close_registered () |> don't_wait_for; Error x
  | _ -> Ok res

let merge_envs_to_spec spec envs =
  let open Spec in
  { spec with envs = List.concat [spec.envs; envs]}

let new_spec' t state spec discoveries_stopper =
  stop_if_needed t state spec.Spec.stop_before >>= fun state' ->
  (Docker.start t.docker spec >>=? (fun container ->
       register_services t spec container >>|? fun services ->
       let deploy = { spec = spec;
                      container = container;
                      services = services;
                      stop_checks = stable_watcher t container services;
                      stop_discoveries = discoveries_stopper;
                      stable = false;
                      created_at = now ();
                      stable_at = None; } in
       if spec.Spec.stop_before
       then { state' with current = Some deploy }
       else { state' with next = Some deploy }) >>= function
   | Ok v -> return v
   | Error err -> print_endline ("Error while applying new spec: " ^ (Utils.of_exn err));
     (match (state'.current, state.current) with
      | (Some _, _) -> return state'
      (* Try to recover prev stable spec *)
      | (None, Some prev) -> schedule_try_again t prev.spec; return state'
      | _ -> return state'))

let new_spec t state spec =
  discoveries_watcher t spec >>= function
  | Ok (discoveries, discoveries_stopper) ->
    let spec' = merge_envs_to_spec spec discoveries in
    new_spec' t state spec' discoveries_stopper
  | Error _ -> return state

let new_discovery t state spec discoveries =
  return state

let now_stable t state container =
  return state

let not_stable t state container =
  return state

let try_again t state spec =
  match (state.current, state.next) with
  | (None, None) -> new_spec t state spec
  | _ -> return state

let apply_change t state change =
  match change with
  | NewSpec spec -> new_spec t state spec
  | NewDiscovery (spec, discoveries) -> new_discovery t state spec discoveries
  | NowStable container -> now_stable t state container
  | NotStable container -> not_stable t state container
  | TryAgain spec -> try_again t state spec

let start t =
  let rec tick state =
    Pipe.read t.changes
    >>= function
    | `Eof -> return ()
    | `Ok change -> apply_change t state change >>= tick in
  tick { current = None; next = None; last_stable = None }

let create consul docker =
  let (r, w) = Pipe.create () in
  { consul = consul;
    docker = docker;
    changes = r;
    changes_w = w; }
