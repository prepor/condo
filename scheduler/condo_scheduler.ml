open Core.Std
open Cmdliner

let start consul services_prefix nodes_prefix roles_prefix server_port =
  Scheduler.create consul ~services_prefix ~nodes_prefix ~roles_prefix ~server_port |> ignore;
  Async.Std.Scheduler.go () |> never_returns

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

let setup_log' is_debug =
  let level = if is_debug then `Debug else `Info in
  Async.Std.Log.Global.set_output [Async.Std.Log.Output.stdout ()];
  Async.Std.Log.Global.set_level level;
  ()

let setup_log =
  Term.(const setup_log' $ debug)

let services_prefix =
  let doc = "KV's prefix with service specs for condo" in
  Arg.(value & opt string "services" & info ["services"] ~doc ~docv:"SERVICES")

let nodes_prefix =
  let doc = "KV's prefix with nodes specs" in
  Arg.(value & opt string "nodes" & info ["nodes"] ~doc ~docv:"NODES")

let roles_prefix =
  let doc = "KV's prefix with roles specs" in
  Arg.(value & opt string "roles" & info ["roles"] ~doc ~docv:"ROLES")

let server_port =
  let doc = "HTTP server port" in
  Arg.(value & opt (some int) None & info ["port"] ~doc ~docv:"PORT")

let info =
  let doc = "Match role specifications with node descriptions and create/delete condo specs. All is done in Consul" in
  Term.info "condo_scheduler" ~version:[%getenv "VERSION"] ~doc

let condo_t = Term.(const start $ consul $ services_prefix $ nodes_prefix $ roles_prefix
                    $ server_port $ setup_log)

let () = match Term.eval (condo_t, info)  with `Error _ -> exit 1 | _ -> exit 0
