(* TODO add remove_after_stop option *)
(* TODO remove Init snapshots from state *)

let start {Condo_cli.docker_config; docker_endpoint; state_path; prefixes;
           expose_state; server; host; ui_prefix} =
  let open Core.Std in
  let open Async.Std in
  Gc.tune ~max_overhead:0 ~space_overhead:10 ();
  Random.self_init ();
  (* Signal.terminating contains hup and we need to handle it
   separately to update Docker config (see Docker.wait_for_config_updates) *)
  let terminating = [Signal.alrm; Signal.int; Signal.term;
                     Signal.usr1; Signal.usr2] in

  (let%map system = Condo_system.create ~state_path
       ~docker_config ~docker_endpoint
       ~expose_state ~host in
   let supervisor = Condo_supervisor.create ~system ~prefixes in
   (match server with
   | Some port -> Condo_server.create system ~port ~ui_prefix |> Deferred.ignore
   | None -> return ()) |> don't_wait_for;

   Shutdown.at_shutdown (fun () -> Condo_supervisor.stop supervisor)) |> don't_wait_for;
  (* 30 min? it should be configurable or we should excplicit about it in
     documentation *)
  let at_shutdown _s =
    Shutdown.shutdown ~force:(after (Time.Span.of_min 30.0)) 0 in
  Signal.handle terminating ~f:at_shutdown;
  never_returns (Scheduler.go ())

let () =
  let open Cmdliner in
  match Term.eval Condo_cli.cmd with
  | `Error _ -> exit 1
  | `Ok v -> start v
  | _ -> exit 0
