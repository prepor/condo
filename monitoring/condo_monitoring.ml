open Core.Std

open Cmdliner

module A = Async.Std

let start monitoring port ui_path =
  Random.self_init ();
  Monitoring_server.create monitoring port ui_path |> A.don't_wait_for;
  (* FIXME host of deployer should be customizable *)
  never_returns (A.Scheduler.go ())

let info =
  let doc = "Monitoring server for condo" in
  Term.info "condo_monitoring" ~version:"%VERSION%" ~doc

let setup_log' is_debug =
  let level = if is_debug then "Debug" else "Info" in
  Async.Std.Log.Global.set_output [Async.Std.Log.Output.stdout ()];
  Async.Std.Log.Global.set_level (Async.Std.Log.Level.of_string level);
  ()

let consul =
  let endpoint =
    let doc = "Set ups Consul API endpoint" in
    let env = Arg.env_var "CONSUL" ~doc in
    Arg.(value & opt string "tcp://0.0.0.0:8500" & info ["consul"] ~env ~doc) in
  let consul' endpoint = Consul.create endpoint in
  Term.(const consul' $ endpoint)

let monitoring =
  let prefix =
    let doc = "Keys prefix in Consul's KV with state data" in
    let env = Arg.env_var "PREFIX" ~doc in
    Arg.(value & opt string "condo" & info ["prefix"] ~env ~doc) in
  let tag =
    let doc = "Tag to filter condo services" in
    let env = Arg.env_var "TAG" ~doc in
    Arg.(value & opt (some string) None & info ["tag"] ~env ~doc) in
  let monitoring' consul prefix tag =
    Monitoring.create consul ~prefix ~tag
  in
  Term.(const monitoring' $ consul $ prefix $ tag)

let port =
  let doc = "Port for listening" in
  Arg.(value & opt int 5000 & info ["p"; "port"] ~doc ~docv:"PORT")

let ui_prefix =
  let doc = "Directory with UI files" in
  let env = Arg.env_var "UI_PREFIX" ~doc in
  Arg.(value & opt (some string) None & info ["ui-prefix"] ~doc ~env ~docv:"DIR_PATH")

let debug =
  let doc = "Debug logs" in
  Arg.(value & flag & info ["d"; "debug"] ~doc)

let setup_log =
  Term.(const setup_log' $ debug)

let condo_t = Term.(const start $ monitoring $ port $ ui_prefix $ setup_log)

let () = match Term.eval (condo_t, info)  with `Error _ -> exit 1 | _ -> exit 0
