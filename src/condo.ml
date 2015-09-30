open Batteries

(* let () = *)
(*   Yojson.Safe.from_string "{\"Image\": {\"Name\": \"helloworld\", \"Tag\": \"latest\"}, \"Envs\": [{\"Key\":\"HOST\", \"Value\": \"localhost\"}]}" *)
(*   |> Spec.spec_of_yojson *)
(*   |> function *)
(*     | `Ok spec -> Spec.show_spec spec |> print_endline *)
(*     | `Error _ -> print_endline "Invalid spec" *)


let () =
  let consul = Consul.create "http://localhost:8500" in
  let (stream, close) = Consul.key consul "test" in
  let open Lwt_stream in
  stream |> iter (fun data -> print_endline ("New key data: " ^ data))
  |> Lwt_main.run
