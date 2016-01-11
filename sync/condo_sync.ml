open Core.Std
open Cmdliner

let start aws consul =
  Aws_syncer.sync consul (fst aws) (snd aws) |> ignore;
  (* Aws.describe_instances (fst aws) ["10.19.0.29"] |> ignore; *)
  Async.Std.Scheduler.go () |> never_returns

let aws =
  let access_key =
    let doc = "AWS access key" in
    let env = Arg.env_var "AWS_ACCESS_KEY_ID" ~doc in
    Arg.(value & opt (some string) None & info ["aws-access-key"] ~env ~doc) in
  let secret_key =
    let doc = "AWS access key" in
    let env = Arg.env_var "AWS_SECRET_ACCESS_KEY" ~doc in
    Arg.(value & opt (some string) None & info ["aws-secret-key"] ~env ~doc) in
  let region =
    let doc = "AWS region" in
    let env = Arg.env_var "AWS_DEFAULT_REGION" ~doc in
    Arg.(value & opt string "us-west-1" & info ["aws-region"] ~env ~doc) in
  let consul_prefix =
    let doc = "Path in Consul's KV with nodes infromation" in
    Arg.(value & opt string "nodes" & info ["aws-consul-prefix"] ~doc) in
  let aws' access_key secret_key region consul_prefix =
    match (access_key, secret_key) with
    | Some access_key, Some secret_key ->
      `Ok ((Aws.create ~access_key ~secret_key ~region ~service:"ec2"), consul_prefix)
    | _ -> `Error (true, "aws-access-key and aws-secret-key are required parameters") in
  Term.(ret (const aws' $ access_key $ secret_key $ region $ consul_prefix))

let consul =
  let endpoint =
    let doc = "Set ups Consul API endpoint" in
    let env = Arg.env_var "CONSUL" ~doc in
    Arg.(value & opt string "tcp://0.0.0.0:8500" & info ["consul"] ~env ~doc) in
  let consul' endpoint = Consul.create endpoint in
  Term.(const consul' $ endpoint)

let setup_log' is_debug =
  let level = if is_debug then `Debug else `Info in
  Async.Std.Log.Global.set_output [Async.Std.Log.Output.stdout ()];
  Async.Std.Log.Global.set_level level;
  ()

let debug =
  let doc = "Debug logs" in
  Arg.(value & flag & info ["d"; "debug"] ~doc)

let setup_log =
  Term.(const setup_log' $ debug)

let info =
  let doc = "Sync data from various sources with Consul's KV" in
  Term.info "condo-sync" ~version:[%getenv "VERSION"] ~doc

let condo_t = Term.(const start $ aws $ consul $ setup_log)

let () = match Term.eval (condo_t, info)  with `Error _ -> exit 1 | _ -> exit 0
