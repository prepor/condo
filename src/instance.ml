open! Core.Std
open! Async.Std

type container = {
  id : Docker.id;
  spec : Spec.t
} [@@deriving sexp]

type snapshot = | Init
                | Wait of container
                | TryAgain of (Spec.t * float)
                | Stable of container
                | WaitNext of (container * container)
                | TryAgainNext of (container * Spec.t * float)
[@@deriving sexp]

type control = Stop | Suspend

type t = { worker : (snapshot, control) Cancellable.t }

let read_spec path =
  let tick () =
    (match%map (Spec.from_file path) with
    | Ok v -> `Complete v
    | Error e ->
        Logs.warn (fun m -> m "Can't read spec from file %s: %s" path e);
        `Continue ())
    |> Cancellable.defer_wait in
  Cancellable.worker ~timeout:1000 ~tick ()

let read_new_spec path current =
  let open Cancellable.Let_syntax in
  let tick () =
    let%map spec = read_spec path in
    if spec = current then `Continue ()
    else `Complete spec in
  Cancellable.worker ~timeout:1000 ~tick ()

let try_again_at () =
  Time.(add (now ()) (Span.of_int_sec 10) |> to_epoch)

let apply system spec_path snapshot control =
  let docker = System.docker system in
  let control' = Cancellable.defer control in
  let name = Utils.name_from_path spec_path in
  let docker_stop container =
    Docker.stop docker container.id ~timeout:container.spec.Spec.stop_timeout in
  (* Common actions *)
  let wait_or_try_again spec =
    match%map Docker.start docker ~name ~spec:spec.Spec.spec with
    | Ok id -> `Continue (Wait {id; spec})
    | Error e -> `Continue (TryAgain (spec, try_again_at ())) in
  let wait_next_or_try_again stable spec =
    match spec.Spec.deploy with
    | Spec.Before ->
        let%bind () = docker_stop stable in
        wait_or_try_again spec
    | Spec.After _ ->
        match%map Docker.start docker ~name ~spec:spec.Spec.spec with
        | Ok id -> `Continue (WaitNext (stable, {id; spec}))
        | Error e -> `Continue (TryAgainNext (stable, spec, try_again_at ())) in

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
    [C.choice (read_spec spec_path) wait_or_try_again;] in
  let wait_choices container =
    let timeout = container.spec.Spec.health_timeout in
    [C.choice (read_new_spec spec_path container.spec)
       (fun spec ->
          docker_stop container >>= fun () ->
          wait_or_try_again spec);
     C.choice (Docker.wait_healthchecks docker container.id ~timeout |> C.defer) (function
       | `Passed -> `Continue (Stable container) |> return
       | `Not_passed -> `Continue (TryAgain (container.spec, try_again_at ()))
                        |> return)] in
  let try_again_choices spec at =
    [C.choice (read_new_spec spec_path spec) wait_or_try_again;
     C.choice (Clock.at (Time.of_epoch at) |> C.defer) (fun () ->
         wait_or_try_again spec)] in
  let stable_choices container =
    Cancellable.
      [choice (read_new_spec spec_path container.spec) (wait_next_or_try_again container)] in
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
              | Error e -> `Continue (TryAgainNext (stable, spec, try_again_at ())));
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
       | `Not_passed -> `Continue (TryAgainNext (stable, next.spec, try_again_at ()))
                        |> return)] in
  let try_again_next_choices stable spec at =
    [C.choice (read_new_spec spec_path spec) (wait_next_or_try_again stable);
     C.choice (Clock.at (Time.of_epoch at) |> C.defer) (fun () ->
         wait_or_try_again spec)] in
  let apply_choices choices =
    C.choose (C.choice control' (function
      | Stop -> stop snapshot
      | Suspend -> return (`Complete snapshot))
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
  let%map () = System.place_snapshot system ~name ~snapshot:(snapshot' |> sexp_of_snapshot) in
  res

let parse_snapshot data =
  Result.try_with (fun () -> snapshot_of_sexp data)
  |> Result.map_error ~f:Exn.to_string

let init_snaphot () = Init

let suspend {worker} =
  Cancellable.cancel worker Stop

let stop {worker} =
  Cancellable.cancel worker Stop

(* FIXME actualize init_snaphot *)
let actualize_snapshot snapshot =
  return snapshot

let create system ~spec ~snapshot =
  let tick last_snapshot =
    Cancellable.wrap (apply system spec last_snapshot) in
  let worker =
    let open Cancellable.Let_syntax in
    let%bind snapshot' = actualize_snapshot snapshot |> Cancellable.defer_wait in
    Cancellable.worker ?timeout:None ~tick snapshot' in
  {worker}
