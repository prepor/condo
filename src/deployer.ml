open Core.Std
open Async.Std

type deploy = {
  spec: Spec.t;
  container: Docker.container;
  services: (Spec.Service.t * Consul.Service.id) list;
  stop_checks: (unit -> unit);
  stop_discoveries: (unit -> unit Deferred.t);
  stop_supervisor: (unit -> unit) option;
  created_at: float;
  stable_at: float option;
}

type state = {
  current: deploy option;
  next: deploy option;
  last_stable: Spec.t option;
}

type change = NewSpec of Spec.t
            | NewDiscovery of Spec.Discovery.t * (string * int) list
            | NowStable of Docker.container
            | NotStable of Docker.container
            | TryAgain of Spec.t
            | ContainerDown of deploy

type t = {
  changes: change Pipe.Reader.t;
  changes_w: change Pipe.Writer.t;
  docker: Docker.t;
  consul: Consul.t;
  host: string;
  advertisements: string Pipe.Writer.t option;
}

let spec_label spec =
  Spec.Image.(sprintf "%s:%s" spec.Spec.image.name spec.Spec.image.tag)

let deregister_services t deploy =
  let f s = Consul.deregister_service t.consul (snd s) in
  List.map deploy.services f |> Deferred.all >>| fun _ -> ()

(* We just ignore fails in stop action *)
let stop' t ?(timeout=0) deploy =
  deploy.stop_checks ();
  deregister_services t deploy >>= fun () ->
  after (Time.Span.of_int_sec timeout) >>= fun () ->
  L.info "Stop container %s of deploy %s"
    (Docker.container_to_string deploy.container) (spec_label deploy.spec);
  let r = deploy.stop_discoveries () >>= fun () ->
    (match deploy.stop_supervisor with
     | Some s -> s (); return ()
     | None -> return ()) >>= fun () ->
    Docker.stop t.docker deploy.container in
  r >>= (function
      | Error err ->
        L.error "Error in stopping of deploy %s, container %s: %s"
          (spec_label deploy.spec) (Docker.container_to_string deploy.container) (Utils.of_exn err);
        return ()
      | Ok _ -> return ())

let stop t = function
  | Some deploy -> stop' t deploy
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
  let wait_for = List.map services (fun (spec, id) ->
      (id, Spec.Service.(Time.Span.of_int_sec spec.check.Spec.Check.timeout))) in
  let (waiter, closer) = Consul.wait_for_passing t.consul wait_for in
  let stable_watcher' = waiter >>= function
    | `Closed -> return ()
    | `Pass -> Pipe.write t.changes_w (NowStable container)
    | `Error err ->
      L.error "Error while stable watching: %s" (Utils.exn_to_string err);
      Pipe.write t.changes_w (NotStable container) in
  stable_watcher' |> don't_wait_for;
  closer

let partition_result l = List.partition_map l ~f: (function
    | Ok v -> `Fst v
    | Error v -> `Snd v)

let discovery_to_env' spec v =
  let open Spec in
  let format_pair = (fun (host, port) -> sprintf "%s:%i" host port ) in
  let mk_env v = { Env.value = v;
                   name = spec.Discovery.env; } in
  match (v, spec.Discovery.multiple) with
  | (v, true) -> List.map v ~f: format_pair |> String.concat ~sep:"," |> mk_env |> Option.some
  | (x::xs, false) -> format_pair x |> mk_env |> Option.some
  | ([], false) -> None

let discovery_to_env spec v =
  Option.value_exn (discovery_to_env' spec v)

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
      Spec.Discovery.(spec, Consul.discovery t.consul ?tag:spec.tag (Consul.Service.of_string spec.service))) in
  let init_services = List.map discoveries' ~f: (fun (spec, (r, _)) ->
      let rec tick () =
        Pipe.read r >>= (function
            | `Eof -> Error ("Can't receive discovery for " ^ spec.Spec.Discovery.service) |> return
            | `Ok [] ->
              L.error "Empty discovery for %s, waiting more" spec.Spec.Discovery.service;
              tick ()
            | `Ok v -> Ok (spec, v) |> return) in
      tick ())
                      |> Deferred.all >>| partition_result in
  let closer () = (List.map discoveries' ~f: (fun (_, (_, stopper)) -> stopper ()))
                  |> Deferred.all >>| (fun _ -> ()) in
  with_timeout (Time.Span.of_int_sec 10) init_services >>= function
  | `Timeout ->
    L.error "Timeout while resolving discoveries";
    closer () >>= fun () ->
    schedule_try_again t spec;
    Error (Failure "Cant resolve discoveries") |> return
  | `Result (init_discoveries, fails) ->
    if (List.length fails) > 0 then Error (Failure "Discoveries failed") |> return
    else
      (List.iter discoveries' ~f: (fun (spec, (r, _)) -> discovery_watcher spec r |> ignore);
       (let vals = List.map init_discoveries ~f: (Tuple.T2.uncurry discovery_to_env) in
        return (Ok (vals, closer))))

let now () = let open Core.Time in now () |> to_epoch

let register_services t spec container ports =
  let container' = Docker.container_to_string container in
  let suffix = Stringext.take container' 12 in
  let register_service service_spec =
    let port = List.Assoc.find_exn ports service_spec.Spec.Service.port in
    let template_vars = [("host", t.host);
                         ("port", string_of_int port);
                         ("container", container')] in
    Consul.register_service t.consul ~id_suffix:suffix service_spec template_vars port >>|?
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
  let envs_to_assoc envs =
    List.map envs (fun {Spec.Env.name; value} -> (name, value)) in
  let assoc_to_envs l = List.map l (fun (name,value) -> {Spec.Env.name; value}) in
  let open Spec in
  { spec with envs = Utils.Assoc.merge (envs_to_assoc spec.envs) (envs_to_assoc envs)
                     |> assoc_to_envs }

let new_spec' t state spec discoveries_stopper =
  stop_if_needed t state spec.Spec.stop_before >>= fun state' ->
  L.info "Starting container for %s" (spec_label spec);
  (Docker.start t.docker spec >>=? (fun (container, ports) ->
       register_services t spec container ports >>= (function
           | Error err -> (Docker.stop t.docker container >>= fun _ ->
                           Error err |> return)
           | Ok services ->
             let deploy = { spec = spec;
                            container = container;
                            services = services;
                            stop_checks = stable_watcher t container services;
                            stop_discoveries = discoveries_stopper;
                            stop_supervisor = None;
                            created_at = now ();
                            stable_at = None; } in
             let state'' = if spec.Spec.stop_before
               then { state' with current = Some deploy }
               else { state' with next = Some deploy } in
             Ok state'' |> return)) >>= function
   | Ok v -> return v
   | Error err ->
     L.error "Error while applying new spec: %s" (Utils.of_exn err);
     (match (state'.current, state.current) with
      | (Some _, _) -> return state'
      (* Try to recover prev stable spec *)
      | (None, Some prev) -> schedule_try_again t prev.spec; return state'
      | _ -> return state'))

let format_discovery { Spec.Env.name; value; _} =
  sprintf "%s -> %s" name value

let new_spec t state spec =
  L.info "New deploy for spec %s. Waiting for discoveries" (spec_label spec);
  discoveries_watcher t spec >>= function
  | Ok (discoveries, discoveries_stopper) ->
    L.info "Init discoveries for spec %s: %s"
      (spec_label spec) (List.map discoveries format_discovery |> String.concat ~sep:", ");
    let spec' = merge_envs_to_spec spec discoveries in
    new_spec' t state spec' discoveries_stopper
  | Error _ -> return state

let new_discovery t state (d_spec, discovery) =
  let env = discovery_to_env' d_spec discovery in
  match env with
  | None -> return state
  | Some env' ->
    let deploy = match state with
      | { current = Some deploy } -> deploy
      | { next = Some deploy } -> deploy
      | _ -> assert false in
    let spec' = merge_envs_to_spec deploy.spec [env'] in
    (* For cases then discovery was changed to None and returned to Some with
       same value. We can save us here from waste restart *)
    if spec' = deploy.spec then return state
    else
      (L.info "New discovery for deploy %s: %s" (spec_label deploy.spec) (format_discovery env');
       let spec' = merge_envs_to_spec deploy.spec [env'] in
       new_spec' t state spec' deploy.stop_discoveries)

let supervisor_watcher t supervisor deploy =
  supervisor >>= function
  | Ok () -> return ()
  | Error err -> Pipe.write t.changes_w (ContainerDown deploy)

let now_stable t state container =
  let (supervisor, stop_supervisor) = Docker.supervisor t.docker container in
  let new_state next =
    let deploy = { next with stop_supervisor = Some stop_supervisor;
                             stable_at = Some (now ())} in
    supervisor_watcher t supervisor deploy |> don't_wait_for;
    return { current = Some deploy;
             next = None;
             last_stable = Some next.spec } in
  match state with
  | { current = Some current_deploy;
      next = Some next_deploy; } ->
    let timeout = current_deploy.spec.Spec.stop_after_timeout in
    L.info "New stable container %s for deploy %s. Stop %s after %i seconds"
      (Docker.container_to_string container) (spec_label next_deploy.spec) (spec_label current_deploy.spec)
      timeout;
    stop' t ~timeout current_deploy >>= fun _ ->
    new_state next_deploy
  | { next = Some next_deploy } ->
    L.info "New stable container %s for deploy %s"
      (Docker.container_to_string container) (spec_label next_deploy.spec);
    new_state next_deploy
  | _ -> assert false

let not_stable t state container =
  match (state.current, state.next, state.last_stable) with
  | (Some deploy, _, Some last_stable) when deploy.container = container ->
    L.error "Not stable container %s for current deploy %s. Stop conatiner and start previous stable spec %s"
      (Docker.container_to_string container) (spec_label deploy.spec) (spec_label last_stable);
    stop' t deploy >>= fun _ ->
    let state' = { state with current = None} in
    new_spec t state' last_stable
  | (Some _, Some deploy, _) when deploy.container = container ->
    L.error "Not stable container %s for next deploy %s. Stop it"
      (Docker.container_to_string container) (spec_label deploy.spec);
    stop' t deploy >>= fun _ ->
    let state' = { state with next = None} in
    return state'
  | (None, Some deploy, _) when deploy.container = container ->
    L.error "Not stable container %s for next deploy %s. But we don't have another one. Try again"
      (Docker.container_to_string container) (spec_label deploy.spec);
    stop' t deploy >>= fun _ ->
    let state' = { state with next = None} in
    schedule_try_again t deploy.spec;
    return state'
  | _ -> assert false

let try_again t state spec =
  L.info "Try again %s" (spec_label spec);
  match (state.current, state.next) with
  | (None, None) -> new_spec t state spec
  | _ -> return state

let container_down t state deploy =
  L.error "Supervisor failed for container %s of deploy %s"
    (Docker.container_to_string deploy.container) (spec_label deploy.spec);
  stop' t deploy >>= fun () ->
  let state' = { state with current = None} in
  try_again t state' deploy.spec

let serialize_state state =
  let serialize_deploy = Option.map ~f:(fun {spec; created_at; stable_at} ->
      {Json.SerializedState.Deploy.image = spec.Spec.image; created_at; stable_at}) in
  {Json.SerializedState.
    current = serialize_deploy state.current;
    next = serialize_deploy state.next;
    last_stable = Option.map state.last_stable (fun {Spec.image} -> image)}
  |> Json.SerializedState.to_yojson |> Yojson.Safe.to_string

let apply_change t state change =
  (match change with
   | NewSpec spec -> new_spec t state spec
   | NewDiscovery (d_spec, discoveries) -> new_discovery t state (d_spec, discoveries)
   | NowStable container -> now_stable t state container
   | NotStable container -> not_stable t state container
   | TryAgain spec -> try_again t state spec
   | ContainerDown deploy -> container_down t state deploy) >>= fun state' ->
  (match t.advertisements with
   | Some w -> Pipe.write w (serialize_state state')
  | None -> return ()) >>| fun () ->
  state'

let at_shutdown t state =
  match state with
  | {current = Some deploy} -> stop' t deploy
  | _ -> return () >>= fun () ->
    match state with
    | {next = Some deploy} -> stop' t deploy
    | _ -> return ()

let start t spec_url =
  let (changes, _close) = Consul.key t.consul spec_url in
  let rec spec_watcher () =
    Pipe.read changes >>= function
    | `Eof -> assert false
    | `Ok s -> let res = try
                   Yojson.Safe.from_string s |> Spec.of_yojson |> function
                   | `Error err -> Error (Failure err)
                   | `Ok spec -> Ok spec
                 with exc -> Error exc in
      match res with
      | Ok spec -> Pipe.write t.changes_w (NewSpec spec) >>= fun _ -> spec_watcher ()
      | Error exn ->
        L.error "Error in parsing spec from %s: %s" spec_url (Utils.exn_to_string exn);
        spec_watcher () in
  let stop_marker = Ivar.create () in
  let rec tick state =
    Pipe.read t.changes
    >>= function
    | `Eof ->
      at_shutdown t state >>= fun () ->
      Ivar.fill stop_marker ();
      return ()
    | `Ok change -> apply_change t state change >>= tick in
  let stopper () = Pipe.close t.changes_w; Ivar.read stop_marker in
  spec_watcher () |> don't_wait_for;
  tick { current = None; next = None; last_stable = None } |> don't_wait_for;
  stopper

let create ?advertiser ~consul ~docker ~host ~spec =
  let (r, w) = Pipe.create () in
  let advertisements = match advertiser with
    | Some a ->
      let (a_r, a_w) = Pipe.create() in
      (Consul.Advertiser.start a >>= (function
           | Error err ->
             L.error "Error while starting advertiser: %s" (Utils.of_exn err);
             Shutdown.shutdown 1;
             return ()
           | Ok (a_w', stopper) ->
             Shutdown.at_shutdown (fun () -> stopper ());
             Pipe.transfer a_r a_w' ~f:Fn.id) |> don't_wait_for);
      Some a_w
    | None -> None in
  let t = { consul; docker; host; advertisements;
            changes = r;
            changes_w = w; } in
  start t spec
