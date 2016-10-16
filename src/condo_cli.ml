open! Core.Std
open! Cmdliner

let endpoint =
  let endpoint_str = function
  | `Unix s -> (sprintf "unix://%s" s)
  | `Inet (h,p) -> (sprintf "tcp://%s:%i" h p) in

  let parse s =
    if Str.string_match (Str.regexp {|unix://\(.+\)|}) s 0 then
      `Ok (`Unix (Str.matched_group 1 s))
    else (if Str.string_match (Str.regexp {|tcp://\(.+\):\([0-9]+\)|}) s 0 then
            `Ok (`Inet ((Str.matched_group 1 s), int_of_string @@ (Str.matched_group 2 s)))
          else `Error "Bad formatted docker endpoint") in
  parse, fun ppf p -> Format.fprintf ppf "%s" (endpoint_str p)

let docker_endpoint =
  let doc = "Docker endpoint" in
  Arg.(value & opt endpoint (`Unix "/var/run/docker.sock") & info ["d"; "docker"] ~docv:"DOCKER" ~doc)

let docker_config =
  let doc = "Json file with auth credentials. Usually is ~/.docker/config.json" in
  Arg.(value & opt (some non_dir_file) None & info ["docker-config"] ~docv:"PATH" ~doc)

let state_path =
  let doc = "Condo dumps its state into local file and restores from it" in
  Arg.(required & opt (some string) None & info ["s"; "state"] ~docv:"STATE_PATH" ~doc)

let prefixes =
  let doc = "Directories with container specifications" in
  Arg.(non_empty & pos_all dir [] & info [] ~docv:"PREFIX" ~doc)

let expose_state =
  let config enum consul_endpoint consul_prefix =
    match enum with
    | `No -> `No
    | `Consul -> `Consul (consul_endpoint, consul_prefix) in
  let enum =
    let alts = [("no", `No); ("consul", `Consul)] in
    let doc = sprintf "Expose state into external storage. Can be %s" @@ Arg.doc_alts_enum alts in
    Arg.(value & opt (enum alts) `No & info ["e"; "expose"] ~doc) in
  let consul_endpoint =
    Arg.(value & opt endpoint (`Inet ("localhost", 8500)) & info ["consul-endpoint"]) in
  let consul_prefix =
    Arg.(value & opt string "/condo" & info ["consul-prefix"] ~docv:"PATH") in
  Term.(const config $ enum $ consul_endpoint $ consul_prefix)

let host =
  let doc = "Name of current host. Can be used in exposed state" in
  Arg.(value & opt (some string) None & info ["host"] ~doc)

let server =
  let doc = "Start HTTP server" in
  Arg.(value & opt (some int) None & info ["server"] ~docv:"PORT" ~doc)

type t = {
  docker_endpoint : Async_http.addr;
  docker_config : string option;
  state_path : string;
  prefixes : string list;
  expose_state : [`No | `Consul of (Async_http.addr * string)];
  server : int option;
  host : string option;
}

let config docker_endpoint docker_config state_path prefixes expose_state server host () =
  {docker_endpoint; docker_config; state_path; prefixes; expose_state; server; host}

let setup_log =
  let setup style_renderer level =
    Fmt_tty.setup_std_outputs ?style_renderer ();
    Logs.set_level level;
    Logs.set_reporter (Logs_fmt.reporter ~pp_header:Logs_fmt.pp_header ());
    () in
  Term.(const setup $ Fmt_cli.style_renderer () $ Logs_cli.level ())

let cmd =
  let doc = "Good daddy for docker containers" in
  Term.(const config $ docker_endpoint $ docker_config $ state_path $ prefixes $ expose_state $ server $ host $ setup_log),
  Term.info "condo" ~doc
