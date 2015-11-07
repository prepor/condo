open Core.Std

open Cmdliner

module A = Async.Std

let start docker endpoint (consul, advertiser) =
  Random.self_init ();
  (* FIXME host of deployer should be customizable *)
  Deployer.start ~consul ~docker
    ~host:(Docker.host docker) ~spec:endpoint ?advertiser;
  (* 30 min? it should be configurable or we should excplicit about it in
     documentation *)
  let at_shutdown _s = A.Shutdown.shutdown ~force:(A.after (Time.Span.of_min 30.0)) 0 in
  A.Signal.handle A.Signal.terminating ~f:at_shutdown;
  never_returns (A.Scheduler.go ())

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
  Term.info "condo" ~version:[%getenv "VERSION"] ~doc

let setup_log' is_debug =
  let level = if is_debug then "Debug" else "Info" in
  Async.Std.Log.Global.set_output [Async.Std.Log.Output.stdout ()];
  Async.Std.Log.Global.set_level (Async.Std.Log.Level.of_string level);
  ()

let docker =
  let endpoint =
    let doc = "Set ups docker API endpoint" in
    let env = Arg.env_var "DOCKER" ~doc in
    Arg.(value & opt string "tcp://0.0.0.0:2376" & info ["docker"] ~env ~doc) in
  let docker' endpoint = Docker.create endpoint in
  Term.(const docker' $ endpoint)

let consul =
  let endpoint =
    let doc = "Set ups Consul API endpoint" in
    let env = Arg.env_var "CONSUL" ~doc in
    Arg.(value & opt string "tcp://0.0.0.0:8500" & info ["consul"] ~env ~doc) in
  let consul' endpoint = Consul.create endpoint in
  Term.(const consul' $ endpoint)

let debug =
  let doc = "Debug logs" in
  Arg.(value & flag & info ["d"; "debug"] ~doc)

let advertise =
  let is_start =
    let doc = "Advertise itself as consul service and store state in KV" in
    Arg.(value & flag & info ["a"; "advertise"] ~doc ~docv:"PORT") in
  let tags =
    let doc = "List of tags with condo will advertise itself" in
    Arg.(value & opt (list string) [] & info ["tag"] ~doc ~docv:"TAG") in
  let prefix =
    let doc = "KV's prefix in which condo will stores it's state if advertising" in
    Arg.(value & opt string "condo" & info ["prefix"] ~doc ~docv:"PREFIX") in
  let advertise' is_start tags prefix consul =
    consul,
    (match is_start with
     | true ->
       Some (Consul.Advertiser.create consul ~tags ~prefix)
     | false -> None)
  in
  Term.(const advertise' $ is_start $ tags $ prefix $ consul)

let setup_log =
  Term.(const setup_log' $ debug)

let condo_t = Term.(const start $ docker $ endpoint $ advertise $ setup_log)

let () = match Term.eval (condo_t, info)  with `Error _ -> exit 1 | _ -> exit 0
