open Core.Std

open Cmdliner

module A = Async.Std

let start docker consul endpoint =
  let consul' = Consul.create consul in
  let docker' = Docker.create docker in
  let deployer = Deployer.create consul' docker' in
  let stopper = Deployer.start deployer endpoint in
  let at_shutdown _s =
    A.Deferred.map (stopper ()) (fun () -> A.Shutdown.shutdown 0)
    |> A.don't_wait_for in
  A.Signal.handle A.Signal.terminating ~f:at_shutdown;
  never_returns (A.Scheduler.go ())

let consul =
  let doc = "Set ups Consul API endpoint" in
  let env = Arg.env_var "CONSUL" ~doc in
  Arg.(value & opt string "tcp://0.0.0.0:8500" & info ["consul"] ~env ~doc)

let docker =
  let doc = "Set ups docker API endpoint" in
  let env = Arg.env_var "DOCKER" ~doc in
  Arg.(value & opt string "tcp://0.0.0.0:2376" & info ["docker"] ~env ~doc)

let endpoint =
  let doc = "Source of spec. Like consul:///services/test.json" in
  let endpoint =
    (* It should be pluggable *)
    let parse v =
      let uri = Uri.of_string v in
      match (Uri.scheme uri, Uri.host uri, Uri.path uri) with
      | (Some "consul", Some "", path) when String.length path > 0 -> `Ok path
      | _ -> `Error "bad spec endpoint" in
    parse, fun ppf p -> Format.fprintf ppf "%s" p in
  Arg.(required & pos 0 (some endpoint) None & info [] ~doc ~docv:"ENDPOINT")

let info =
  let doc = "Good daddy for docker containers" in
  Term.info "condo" ~version:"%VERSION%" ~doc

let setup_log' is_debug =
  let level = if is_debug then "Debug" else "Info" in
  Async.Std.Log.Global.set_output [Async.Std.Log.Output.stdout ()];
  Async.Std.Log.Global.set_level (Async.Std.Log.Level.of_string level);
  ()

let debug =
  let doc = "Debug logs" in
  Arg.(value & flag & info ["d"; "debug"] ~doc)

let setup_log =
  Term.(const setup_log' $ debug)

let condo_t = Term.(const start $ docker $ consul $ endpoint $ setup_log)

let () = match Term.eval (condo_t, info)  with `Error _ -> exit 1 | _ -> exit 0
