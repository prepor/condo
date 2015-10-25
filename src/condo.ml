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
  let doc = "Source of spec. Like consul://services/test.json" in
  Arg.(required & pos 0 (some string) None & info [] ~doc ~docv:"ENDPOINT")

let info =
  let doc = "Good daddy for docker containers" in
  Term.info "condo" ~version:"%VERSION%" ~doc

let condo_t = Term.(const start $ docker $ consul $ endpoint)

let () = match Term.eval (condo_t, info)  with `Error _ -> exit 1 | _ -> exit 0


(* let read_key vals = *)
(*   Pipe.read vals >>| function *)
(*   | `Ok v -> print_endline v *)
(*   | `Eof -> print_endline "Completed" *)

(* let read_discovery vals = *)
(*   Pipe.read vals >>| function *)
(*   | `Ok v -> List.iter v ~f: (fun (ip, port) -> printf "New discovery: %s:%i\n" ip port) *)
(*   | `Eof -> print_endline "Completed" *)

(* let run () = *)
(*   let consul = Consul.create "http://localhost:8500" in *)
(*   let (vals, close) = Consul.key consul "test" in *)
(*   (\* let (vals, close) = Consul.discovery consul "http-balancer" in *\) *)
(*   let rec loop () = *)
(*     read_key vals >>= fun _ -> loop () in *)
(*   loop () *)

(* let () = *)
(*   ignore (run ()); *)
(*   never_returns (Scheduler.go ()) *)



(* let () = *)
(*   Yojson.Safe.from_string "{\"Image\": {\"Name\": \"helloworld\", \"Tag\": \"latest\"}, \"Envs\": [{\"Key\":\"HOST\", \"Value\": \"localhost\"}]}" *)
(*   |> Spec.spec_of_yojson *)
(*   |> function *)
(*     | `Ok spec -> Spec.show_spec
       spec |> print_endline *)
(*     | `Error _ -> print_endline "Invalid spec" *)


(* let () = *)
(*   while%lwt true do *)
(*     let consul = Consul.create "http://127.0.0.1:8500" in *)
(*     let (stream, close) = Consul.key consul "test" in *)
(*     let open Lwt_stream in *)
(*     stream *)
(*     |> iter (fun data -> print_endline ("New key data: " ^ data)) *)
(*   done *)
(*   |> Lwt_main.run *)

(* let () = *)
(*   let consul = Consul.create "http://127.0.0.1:8500" in *)
(*   let (stream, close) = Consul.key consul "test" in *)
(*   let open Lwt_stream in *)
(*   stream *)
(*   |> iter (fun data -> print_endline ("New key data: " ^ data)) *)
(*   |> Lwt_main.run *)


(* let () = *)
(*   ignore (Cohttp_lwt_unix_debug .debug_active := true); *)
(*   let rec loop () = *)
(*     print_endline "Tick"; *)
(*     let consul = Consul.create "http://127.0.0.1:8500" in *)
(*     let (stream, close) = Consul.key consul "test" in *)
(*     Lwt_unix.sleep 0.1 >>= fun _ -> *)
(*     close (); *)
(*     loop () in *)
(*   Lwt_main.run (loop ()) *)



(* let () = *)
(*   ignore (Cohttp_lwt_unix_debug .debug_active := true); *)
(*   let connect () = *)
(*     print_endline "Connnect!"; *)
(*     Client.get (Uri.of_string "http://127.0.0.1:8500/v1/kv/test?raw") >>= fun _ -> *)
(*     Lwt_io.eprintl "Completed!" in *)
(*   let rec loop () = *)
(*     (\* let t = connect () in *\) *)
(*     Lwt_unix.sleep 0.1 >>= fun _ -> *)
(*     (\* cancel t; *\) *)
(*     connect () >>= fun _ -> *)
(*     loop () in *)
(*   Lwt_main.run (loop ()) *)

(* open Lwt *)
(* open Cohttp *)
(* open Cohttp_lwt_unix *)

(* let () = *)
(*   let connect () = *)
(*     Client.get (Uri.of_string "http://127.0.0.1:8500/v1/kv/test?index=99&raw") >>= fun (resp,body) -> *)
(*     body |> Cohttp_lwt_body.to_string >>= fun _ -> *)
(*     Lwt_io.eprintl "Completed!" in *)
(*   let rec loop () = *)
(*     let c = connect () in *)
(*     cancel c; *)
(*     Lwt_unix.sleep 0.1 >>= fun _ -> *)
(*     loop () in *)
(*   Lwt_main.run (loop ()) *)
