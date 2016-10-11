open! Core.Std
open! Cmdliner

let docker_endpoint =
  let endpoint_str = function
  | `Unix s -> (sprintf "unix://%s" s)
  | `Inet (h,p) -> (sprintf "tcp://%s:%i" h p) in
  let endpoint =
    let parse s =
      if Str.string_match (Str.regexp {|unix://\(.+\)|}) s 0 then
        `Ok (`Unix (Str.matched_group 1 s))
      else (if Str.string_match (Str.regexp {|tcp://\(.+\):\([0-9]+\)|}) s 0 then
              `Ok (`Inet ((Str.matched_group 1 s), int_of_string @@ (Str.matched_group 2 s)))
            else `Error "Bad formatted docker endpoint") in
    parse, fun ppf p -> Format.fprintf ppf "%s" (endpoint_str p) in
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

type t = {
  docker_endpoint : Async_http.addr;
  docker_config : string option;
  state_path : string;
  prefixes : string list;
}

let config docker_endpoint docker_config state_path prefixes () =
  {docker_endpoint; docker_config; state_path; prefixes}

let setup_log =
  let setup style_renderer level =
    Fmt_tty.setup_std_outputs ?style_renderer ();
    Logs.set_level level;
    Logs.set_reporter (Logs_fmt.reporter ~pp_header:Logs_fmt.pp_header ());
    () in
  Term.(const setup $ Fmt_cli.style_renderer () $ Logs_cli.level ())

let cmd =
  let doc = "Good daddy for docker containers" in
  Term.(const config $ docker_endpoint $ docker_config $ state_path $ prefixes $ setup_log),
  Term.info "condo" ~doc
