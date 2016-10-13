open! Core.Std
open! Async.Std

module Docker = Condo_docker
module Cancel = Cancellable
module Spec = Condo_spec

type container = {
  id : Docker.id;
  spec : Spec.t
} [@@deriving sexp, yojson]

type snapshot = | Init
                | Wait of container
                | TryAgain of (Spec.t * float)
                | Stable of container
                | WaitNext of (container * container)
                | TryAgainNext of (container * Spec.t * float)
[@@deriving sexp, yojson]

type control = Stop | Suspend

type t = { worker : (snapshot, control) Cancel.t }

let read_spec path =
  let tick () =
    (match%map (Spec.from_file path) with
    | Ok v -> `Complete v
    (* Just for better logging. File absence for small amount of time is
       legal for us, because supervisor needs some time to detect it and stops
       instance *)
    | Error (Unix.Unix_error (Unix.ENOENT, _, _)) -> `Continue ()
    | Error e ->
        Logs.warn (fun m -> m "Can't read spec from file %s: %s" path (Exn.to_string e));
        `Continue ()) in
  Cancel.worker ~sleep:1000 ~tick:(Cancel.wrap_tick tick) ()

let read_new_spec path current =
  let open Cancel.Let_syntax in
  let tick () =
    let%map spec = read_spec path in
    if spec = current then `Continue ()
    else `Complete spec in
  Cancel.worker ~sleep:1000 ~tick ()

let try_again_at () =
  Time.(add (now ()) (Span.of_int_sec 10) |> to_epoch)

(* FIXME error handling *)
let apply system spec_path snapshot control =
  let docker = Condo_system.docker system in
  let control' = Cancel.defer control in
  let name = Condo_utils.name_from_path spec_path in
  let docker_stop container =
    Docker.stop docker container.id ~timeout:container.spec.Spec.stop_timeout in
  (* Common actions *)
  let wait_or_try_again spec =
    match%map Docker.start docker ~name ~spec:spec.Spec.spec with
    | Ok id -> `Continue (Wait {id; spec})
    | Error e ->
        Logs.err (fun m -> m "%s --> Error while starting container: %s" name e);
        `Continue (TryAgain (spec, try_again_at ())) in
  let wait_next_or_try_again stable spec =
    match spec.Spec.deploy with
    | Spec.Before ->
        let%bind () = docker_stop stable in
        wait_or_try_again spec
    | Spec.After _ ->
        match%map Docker.start docker ~name ~spec:spec.Spec.spec with
        | Ok id -> `Continue (WaitNext (stable, {id; spec}))
        | Error e ->
            Logs.err (fun m -> m "%s --> Error while starting container: %s" name e);
            `Continue (TryAgainNext (stable, spec, try_again_at ())) in

  let stop snapshot =
    let%map () = (match snapshot with
      | Init -> return ()
      | Wait c -> docker_stop c
      | WaitNext (stable, next) ->
          let%bind () = docker_stop stable in
          docker_stop next
      | Stable c -> docker_stop c
      | TryAgain _ -> return ()
      | TryAgainNext (stable, _, _) -> docker_stop stable) in
    `Complete Init in

  let module C = Cancellable in

  (* State choices *)
  let init_choices () =
    let open C in
    let spec = (read_spec spec_path) in
    [spec --> wait_or_try_again;] in
  let wait_choices container =
    let timeout = container.spec.Spec.health_timeout in
    let new_spec = (read_new_spec spec_path container.spec) in
    let health_check = (Docker.wait_healthchecks docker container.id ~timeout |> C.defer) in
    let stop_and_start spec =
      let%bind () = docker_stop container in
      wait_or_try_again spec in
    C.([new_spec --> stop_and_start;
        health_check --> (function
          | `Passed -> `Continue (Stable container) |> Deferred.return
          | `Not_passed ->
              Logs.warn (fun m -> m "%s --> Health checked not passed in %i secs" name timeout);
              `Continue (TryAgain (container.spec, try_again_at ()))
              |> Deferred.return)]) in
  let try_again_choices spec at =
    let open C in
    let new_spec = (read_new_spec spec_path spec) in
    let timeout = (Clock.at (Time.of_epoch at) |> C.defer) in
    [new_spec --> wait_or_try_again;
     timeout --> (fun () -> wait_or_try_again spec)] in
  let stable_choices container =
    let new_spec = (read_new_spec spec_path container.spec) in
    C.[
      new_spec --> (wait_next_or_try_again container)] in
  let wait_next_choices stable next =
    let timeout = next.spec.Spec.health_timeout in
    [C.choice (read_new_spec spec_path next.spec)
       (fun spec ->
          match spec.Spec.deploy with
          | Spec.Before ->
              let%bind () = docker_stop stable in
              let%bind () = docker_stop next in
              wait_or_try_again spec
          | Spec.After timeout ->
              let%bind () = docker_stop next in
              match%map Docker.start docker ~name ~spec:spec.Spec.spec with
              | Ok id -> `Continue (WaitNext (stable, {id; spec}))
              | Error e ->
                  Logs.err (fun m -> m "%s --> Error while starting container: %s" name e);
                  `Continue (TryAgainNext (stable, spec, try_again_at ())));
     C.choice (Docker.wait_healthchecks docker next.id ~timeout |> C.defer) (function
       | `Passed ->
           (match next.spec.Spec.deploy with
           | Spec.Before ->
               let%map () = docker_stop stable in
               `Continue (Stable next)
           | Spec.After timeout ->
               (* should we block here? *)
               let%bind () = after (Time.Span.of_int_sec timeout) in
               let%map () = docker_stop stable in
               `Continue (Stable next))
       | `Not_passed ->
           Logs.warn (fun m -> m "%s --> Health checked not passed in %i secs" name timeout);
           `Continue (TryAgainNext (stable, next.spec, try_again_at ()))
           |> return)] in
  let try_again_next_choices stable spec at =
    let new_spec = (read_new_spec spec_path spec) in
    let timeout = (Clock.at (Time.of_epoch at) |> C.defer) in
    C.[
      new_spec --> (wait_next_or_try_again stable);
      timeout --> (fun () -> wait_or_try_again spec)] in
  let apply_choices choices =
    C.choose (C.choice control' (function
      | Stop ->
          Logs.app (fun m -> m "%s --> Stop" name);
          stop snapshot
      | Suspend ->
          Logs.app (fun m -> m "%s --> Suspend" name);
          return (`Complete snapshot))
              ::choices)
    |> Deferred.join in

  let choices = match snapshot with
  | Init -> init_choices ()
  | Wait container -> wait_choices container
  | TryAgain (spec, at) -> try_again_choices spec at
  | Stable container -> stable_choices container
  | WaitNext (stable, next) -> wait_next_choices stable next
  | TryAgainNext (stable, spec, at) -> try_again_next_choices stable spec at in
  let%bind res = apply_choices choices in
  let snapshot' = match res with | `Continue v | `Complete v -> v in
  let%map () =
    Logs.app (fun m -> m "%s --> New state: %s" name (snapshot' |> sexp_of_snapshot |> Sexp.to_string_hum));
    Condo_system.place_snapshot system ~name ~snapshot:(snapshot' |> snapshot_to_yojson) in
  res

let parse_snapshot data = snapshot_of_yojson data

let init_snaphot () = Init

let suspend {worker} =
  Cancel.cancel worker Suspend

let stop {worker} =
  Cancel.cancel worker Stop

let actualize_snapshot system snapshot =
  let is_running container = Docker.is_running (Condo_system.docker system) container.id in
  match snapshot with
  | Init | TryAgain _ -> return snapshot
  | Wait container | Stable container -> begin
      match%map is_running container with
      | true -> snapshot
      | false ->
          Logs.warn (fun m -> m "Container from state is not alive, we will try to start it later");
          TryAgain (container.spec, (try_again_at ()))
    end
  | TryAgainNext (container, spec, at) -> begin
      match%map is_running container with
      | true -> snapshot
      | false ->
          Logs.warn (fun m -> m "Stable container from state is not alive, we will try to start it later");
          TryAgain (spec, at)
    end
  | WaitNext (stable, next) -> begin
      let%bind is_running_stable = is_running stable in
      let%map is_running_next = is_running next in
      match is_running_stable, is_running_next with
      | true, true -> snapshot
      | false, true ->
          Logs.warn (fun m -> m "Stable container from state is not alive, we will wait for the next");
          Wait next
      | true, false ->
          Logs.warn (fun m -> m "Next container is not alive, we will try to start it later");
          TryAgainNext (stable, next.spec, try_again_at ())
      | false, false ->
          Logs.warn (fun m -> m "Containers from state is not alive, we will try to start one of them later");
          TryAgain (next.spec, try_again_at ())
    end

let create system ~spec ~snapshot =
  Logs.app (fun m -> m "New instance from %s with state %s" spec
               (Sexp.to_string_hum @@ sexp_of_snapshot snapshot));
  let tick last_snapshot =
    Cancel.wrap (apply system spec last_snapshot) in
  let worker =
    let open Cancel.Let_syntax in
    let%bind snapshot' = actualize_snapshot system snapshot |> Cancel.defer in
    Cancel.worker ?sleep:None ~tick snapshot' in
  {worker}
