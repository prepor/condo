open Core.Std
open Async.Std

let () =
  (* while true do *)
  (*   let i = Ivar.create () in *)
  (*   Deferred.upon (Ivar.read i) (fun v -> print_endline "DEEE"); *)
  (* done; *)
  Random.self_init ();
  (match%map Condo.Spec.from_file "specs/nginx.edn" with
  | Ok spec ->
      print_endline (Sexp.to_string_hum (Condo.Spec.sexp_of_t spec))
  | Error error ->
      printf "Error while decoding: %s\n" error) |> don't_wait_for;
  never_returns (Scheduler.go ())
