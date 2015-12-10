open Core.Std
open Async.Std

type discovery_changes = (Spec.Discovery.t * (string * int) list Pipe.Reader.t) list

type deploy = {
  spec : Spec.t;
  container : Docker.container;
  services : (Spec.Service.t * Consul.Service.id) list;
  discoveries : discovery_changes * (unit -> unit Deferred.t);
  stop_checks : (unit -> unit);
  stop_supervisor : (unit -> unit) option;
  created_at : float;
  stable_at : float option;
}

let deploy_to_yojson deploy =
  `Assoc [("image", Spec.Image.to_yojson deploy.spec.Spec.image);
          ("container", `String (Docker.container_to_string deploy.container));
          ("created_at", `Float deploy.created_at);
          ("stable_at", match deploy.stable_at with
            | Some v -> `Float v
            | None -> `Null)]

let deploy_of_yojson _ = assert false

type state = Init
           | Waiting of deploy
           | WaitingNext of deploy * deploy
           | Started of deploy
           | Stopped [@@deriving yojson]

type event = NewSpec of Spec.t
           | NewDiscovery of Spec.Discovery.t * (string * int) list
           | Stable
           | NotStable
           | TryAgain of Spec.t
           | Down
           | Stop [@@deriving yojson]

type t = {
  docker: Docker.t;
  consul: Consul.t;
  host: string;
  events: event Pipe.Writer.t;
  advertisements: string Pipe.Writer.t option;
}

let stable_watcher t container services =
  let wait_for = List.map services (fun (spec, id) ->
      (id, Spec.Service.(Time.Span.of_int_sec spec.check.Spec.Check.timeout))) in
  let (waiter, closer) = Consul.wait_for_passing t.consul wait_for in
  let stable_watcher' = waiter >>= function
    | `Closed -> return ()
    | `Pass -> Pipe.write t.events Stable
    | `Error err ->
      L.error "Error while stable watching: %s" (Utils.exn_to_string err);
      Pipe.write t.events NotStable in
  stable_watcher' |> don't_wait_for;
  closer

let spec_label spec =
  Spec.Image.(sprintf "%s:%s" spec.Spec.image.name spec.Spec.image.tag)

let deregister_services t deploy =
  let f s = Consul.deregister_service t.consul (snd s) in
  List.map deploy.services f |> Deferred.all >>| fun _ -> ()

let partition_result l = List.partition_map l ~f: (function
    | Ok v -> `Fst v
    | Error v -> `Snd v)

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

let now () = let open Core.Time in now () |> to_epoch

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

let discoveries_watcher t discoveries =
  let discovery_watcher d_spec r =
    Pipe.iter r ~f: (fun v -> Pipe.write t.events (NewDiscovery (d_spec, v)) ) in
  List.iter discoveries ~f: (fun (spec, r) -> discovery_watcher spec r |> ignore)

let discoveries_init t spec =
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
  let make_closer = fun discoveries ->
    fun () -> discoveries
              |> List.map ~f: (fun (_, (_, stopper)) -> stopper ())
              |> Deferred.all >>| fun _ -> () in
  let (watched, unwatched) = discoveries' |> List.partition_tf ~f: (fun (spec, _) ->
    if not spec.Spec.Discovery.watch then
      L.info "Discovery %s won't be watched after initial resolvement" spec.Spec.Discovery.service;
    spec.Spec.Discovery.watch) in
  let (watched_closer, unwatched_closer) = (make_closer watched, make_closer unwatched) in
  with_timeout (Time.Span.of_int_sec 10) init_services >>= function
  | `Timeout ->
    L.error "Timeout while resolving discoveries";
    watched_closer () >>= fun () ->
    unwatched_closer () >>= fun () ->
    Error (Failure "Cant resolve discoveries") |> return
  | `Result (init_discoveries, fails) ->
    if (List.length fails) > 0 then Error (Failure "Discoveries failed") |> return
    else
      unwatched_closer () >>= fun () ->
      let discoveries_as_envs = List.map init_discoveries ~f:(Tuple.T2.uncurry discovery_to_env) in
      Ok (discoveries_as_envs, List.map watched (fun (spec, (r, _)) -> (spec, r)), watched_closer)
      |> return

let new_deploy t spec discoveries =
  L.info "Starting container for %s" (spec_label spec);
  Docker.start t.docker spec >>=? fun (container, ports) ->
  register_services t spec container ports >>= function
  | Error err ->
    (snd discoveries) () >>= fun () ->
    (Docker.stop t.docker container >>= fun _ -> Error err |> return)
  | Ok services ->
    Ok { spec = spec;
         container = container;
         services = services;
         stop_checks = stable_watcher t container services;
         discoveries = discoveries;
         stop_supervisor = None;
         created_at = now ();
         stable_at = None; }
    |> return

let schedule_try_again t spec =
  after (Time.Span.of_int_sec 5) >>= (fun _ ->
      Pipe.write t.events (TryAgain spec))
  |> don't_wait_for

let merge_envs_to_spec spec envs =
  let envs_to_assoc envs =
    List.map envs (fun {Spec.Env.name; value} -> (name, value)) in
  let assoc_to_envs l = List.map l (fun (name,value) -> {Spec.Env.name; value}) in
  let open Spec in
  { spec with envs = Utils.Assoc.merge (envs_to_assoc spec.envs) (envs_to_assoc envs)
                     |> assoc_to_envs }

(* We just ignore fails in stop action *)
let stop t ?(timeout=0) deploy =
  deploy.stop_checks ();
  (snd deploy.discoveries) () >>= fun () ->
  deregister_services t deploy >>= fun () ->
  after (Time.Span.of_int_sec timeout) >>= fun () ->
  L.info "Stop container %s of deploy %s"
    (Docker.container_to_string deploy.container) (spec_label deploy.spec);
  let r = (snd deploy.discoveries) () >>= fun () ->
    (match deploy.stop_supervisor with
     | Some s -> s (); return ()
     | None -> return ()) >>= fun () ->
    Docker.stop t.docker deploy.container in
  r >>= (function
      | Error err ->
        L.error "Error in stopping of deploy %s, container %s:\n%s"
          (spec_label deploy.spec) (Docker.container_to_string deploy.container) (Utils.of_exn err);
        return ()
      | Ok _ -> return ())

let deploy t spec =
  discoveries_init t spec >>=? fun (init, changes, closer) ->
  let spec' = merge_envs_to_spec spec init in
  new_deploy t spec' (changes, closer) >>|? fun deploy ->
  deploy

let format_discovery { Spec.Env.name; value; _} =
  sprintf "%s -> %s" name value

let format_discovery_raw spec value =
  discovery_to_env spec value |> format_discovery

let with_new_discovery spec (d_spec, discovery) =
  let env = discovery_to_env' d_spec discovery in
  match env with
  | None -> None
  | Some env' ->
    let spec' = merge_envs_to_spec spec [env'] in
    (* For cases then discovery was changed to None and returned to Some with
       same value. We can save us here from waste restart *)
    if spec' = spec then None
    else
      (L.info "New discovery for deploy %s: %s" (spec_label spec) (format_discovery env');
       Some spec')

let at_stable t deploy =
  let supervisor_watcher t supervisor deploy =
    supervisor >>= function
    | Ok () -> return ()
    | Error err -> Pipe.write t.events Down in
  let (supervisor, stop_supervisor) = Docker.supervisor t.docker deploy.container in
  supervisor_watcher t supervisor deploy |> don't_wait_for;
  discoveries_watcher t (fst deploy.discoveries);
  { deploy with stop_supervisor = Some stop_supervisor;
                stable_at = Some (now ())}

let init_deploy t spec =
  L.info "Initialized deploy %s" (spec_label spec);
  deploy t spec >>= function
  | Ok deploy -> Waiting deploy |> return
  | Error err ->
    L.error "Error while deploying %s:\n%s" (spec_label spec) (Utils.exn_to_string err);
    schedule_try_again t spec;
    return Init

let started_deploy t current_deploy spec =
  L.info "New deploy %s. Current %s" (spec_label spec) (spec_label current_deploy.spec);
  L.debug "Spec: %s" (Spec.show spec);
  deploy t spec >>| function
  | Ok next_deploy -> WaitingNext (current_deploy, next_deploy)
  | Error err ->
    L.error "Error while deploying %s:\n%s" (spec_label spec) (Utils.exn_to_string err);
    Started current_deploy

let failed_deploy t deploy =
  L.error "Deploy failed %s. We'll try again after few seconds" (spec_label deploy.spec);
  stop t deploy >>| fun () ->
  schedule_try_again t deploy.spec;
  Init

let init_new_spec = init_deploy

let init_try_again = init_deploy

let waiting_new_spec t deploy spec =
  L.info "New spec %s. Current %s. Stop current and start new" (spec_label spec) (spec_label deploy.spec);
  L.debug "Spec: %s" (Spec.show spec);
  stop t deploy >>= fun () ->
  init_deploy t spec

let waiting_stop t deploy =
  stop t deploy >>| fun () ->
  Stopped

let waiting_stable t deploy =
  L.info "Deploy %s is stable now" (spec_label deploy.spec);
  let deploy' = at_stable t deploy in
  Started deploy' |> return

let waiting_not_stable = failed_deploy

let waiting_next_new_spec_before t current next spec =
  L.info "New spec %s. We are stopping %s and %s to deploy it"
    (spec_label spec) (spec_label current.spec) (spec_label next.spec);
  L.debug "Spec: %s" (Spec.show spec);
  stop t current >>= fun () ->
  stop t next >>= fun () ->
  init_deploy t spec

let waiting_next_new_spec_after t current next spec =
  L.info "New spec %s. We are stopping %s to deploy it"
    (spec_label spec) (spec_label next.spec);
  L.debug "Spec: %s" (Spec.show spec);
  stop t next >>= fun () ->
  deploy t spec >>| function
  | Ok deploy -> WaitingNext (current, deploy)
  | Error err ->
    L.error "Error while deploying %s. Stays with stable %s. Error:\n %s"
      (spec_label spec) (spec_label current.spec) (Utils.of_exn err);
    Started current

let waiting_next_stop t current next =
  stop t next >>= fun () ->
  stop t current >>= fun () ->
  Stopped |> return

let waiting_next_stable t current next =
  let timeout = match current.spec.Spec.stop with
    | Spec.After n -> n
    | Spec.Before -> 0 in
  L.info "Next deploy %s now is stable. We'll stop previous %s after %i seconds"
    (spec_label next.spec) (spec_label current.spec) timeout;
  stop t ~timeout:timeout current >>= fun () ->
  let next' = at_stable t next in
  Started next' |> return

let waiting_next_not_stable t current next =
  L.error "Next deploy %s is not stable (health checks failed). Stays with stable %s"
    (spec_label next.spec) (spec_label current.spec);
  stop t next >>= fun () ->
  Started current |> return

let waiting_next_new_discovery t current next (d_spec, discoveries) =
  L.info "New discovery value %s for %s while we are waiting for a next deploy %s. Ignores it"
    (format_discovery_raw d_spec discoveries) (spec_label current.spec) (spec_label next.spec);
  WaitingNext (current, next) |> return

let waiting_next_down t current next =
  L.error "Current container of deploy %s is down while we are waiting for %s. Continue to wait for %s"
    (spec_label current.spec) (spec_label next.spec) (spec_label next.spec);
  stop t current >>= fun () ->
  Waiting next |> return

let started_new_spec_before t deploy spec =
  L.info "New spec %s. Stopping %s and deploy it"
    (spec_label spec) (spec_label deploy.spec);
  L.debug "Spec:\n%s" (Spec.show spec);
  stop t deploy >>= fun () ->
  init_deploy t spec

let started_new_spec_after = started_deploy

let started_new_discovery_before t deploy discovery =
  match with_new_discovery deploy.spec discovery with
  | Some spec' ->
    stop t deploy >>= fun () ->
    init_deploy t spec'
  | None -> Started deploy |> return

let started_new_discovery_after t current_deploy discovery =
  match with_new_discovery current_deploy.spec discovery with
  | Some spec' ->
    started_deploy t current_deploy spec'
  | None -> Started current_deploy |> return

let started_stop t deploy =
  stop t deploy >>= fun () ->
  Stopped |> return

let started_down = failed_deploy

let unexpected state e =
  L.error "Unexpected event in % state:\n%s" state (event_to_yojson e |> Yojson.Safe.to_string)

let apply t = function
  | Init -> (function
      | NewSpec spec -> init_new_spec t spec
      | TryAgain spec -> init_try_again t spec
      | Stop -> return Stopped
      | e -> unexpected "Init" e; Init |> return)
  | Waiting deploy -> (function
      | NewSpec spec -> waiting_new_spec t deploy spec
      | TryAgain spec -> Waiting deploy |> return
      | Stop -> waiting_stop t deploy
      | Stable -> waiting_stable t deploy
      | NotStable -> waiting_not_stable t deploy
      | e -> unexpected "Waiting" e; Waiting deploy |> return)
  | WaitingNext (current, next) -> (function
      | NewSpec spec -> (match spec.Spec.stop with
          | Spec.Before -> waiting_next_new_spec_before t current next spec
          | Spec.After _ -> waiting_next_new_spec_after t current next spec)
      | TryAgain spec -> WaitingNext (current, next) |> return (* ignores *)
      | Stop -> waiting_next_stop t current next
      | Stable -> waiting_next_stable t current next
      | NotStable -> waiting_next_not_stable t current next
      | NewDiscovery (d_spec, discoveries) -> waiting_next_new_discovery t current next (d_spec, discoveries)
      | Down -> waiting_next_down t current next)
  | Started deploy -> (function
      | NewSpec spec -> (match deploy.spec.Spec.stop with
          | Spec.Before -> started_new_spec_before t deploy spec
          | Spec.After _ -> started_new_spec_after t deploy spec)
      | TryAgain spec -> Started deploy |> return
      | Stop -> started_stop t deploy
      | NewDiscovery (d_spec, discoveries) -> (match deploy.spec.Spec.stop with
          | Spec.Before -> started_new_discovery_before t deploy (d_spec, discoveries)
          | Spec.After _ -> started_new_discovery_after t deploy (d_spec, discoveries))
      | Down -> started_down t deploy
      | e -> unexpected "Started" e; Started deploy |> return)
  | Stopped -> (fun e -> unexpected "Stopped" e; Stopped |> return)

let validate_stop_strategy spec =
  let open Spec in
  match spec.stop with
  | Before -> true
  | After _ ->
    let has_host_port_services = spec.services |> List.exists ~f: (fun s ->
      match s.Service.host_port with None -> false | Some _ -> true) in
    not has_host_port_services

let spec_watcher t spec_url =
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
      | Ok spec ->
        if validate_stop_strategy spec then
          Pipe.write t.events (NewSpec spec) >>= fun _ -> spec_watcher ()
        else
          (L.error "Invalid spec: stop strategy \"After\" is not allowed for services with \"host_port\"";
          spec_watcher ())
      | Error exn ->
        L.error "Error in parsing spec from %s: %s" spec_url (Utils.exn_to_string exn);
        spec_watcher () in
  spec_watcher ()

let serialize_state state =
  state_to_yojson state |> Yojson.Safe.to_string

let start' t events spec_url =
  let rec tick state =
    (match t.advertisements with
     | Some w ->
       let s = (serialize_state state) in
       L.debug "Advertise state:\n%s" s;
       Pipe.write w s
     | None -> return ()) >>= fun () ->
    Pipe.read events
    >>= function
    | `Eof -> assert false
    | `Ok change -> apply t state change >>= function
      | Stopped -> return ()
      | state' -> tick state' in
  spec_watcher t spec_url |> don't_wait_for;
  let loop = tick Init in
  Shutdown.at_shutdown (fun () ->
      Pipe.write t.events Stop >>= fun () ->
      loop)

let start ?advertiser ~consul ~docker ~host ~spec =
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
  let t = { consul; docker; host;
            advertisements;
            events = w } in
  start' t r spec
