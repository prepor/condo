(*---------------------------------------------------------------------------
   Copyright (c) 2016 Andrew Rudenko. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
   %%NAME%% %%VERSION%%
  ---------------------------------------------------------------------------*)
open! Core.Std
open! Async.Std

open System_test
open Docker_test
open Instance_test
open Supervisor_test

(* let () = *)
(*   let f = (Writer.to_formatter (Lazy.force Writer.stdout)) in *)
(*   Logs.set_reporter (Logs.format_reporter ~dst:f ~app:f ()); *)
(*     Logs.Src.set_level Logs.default (Some Logs.Debug); *)
(*   (\* Logs.set_level (Some Logs.Debug); *\) *)
(*   (let module D = Docker in *)
(*    let docker () = *)
(*      D.create ~endpoint:(`Inet ("localhost", 3375)) ~config_path:None in *)

(*    let%bind d = docker () in *)
(*    let spec = `Assoc [(`Keyword (None, "image"), `String "prepor/condo-test:bad")] in *)
(*    let%bind res = D.start d ~name:"nginx" ~spec in *)
(*    let%map res = D.wait_healthchecks d (Result.ok_or_failwith res) ~timeout:1 in *)
(*    ()) |> don't_wait_for; *)
(*   never_returns (Scheduler.go ()) *)


(* let () = *)
(*   let f = (Writer.to_formatter (Lazy.force Writer.stdout)) in *)
(*   Logs.set_reporter (Logs.format_reporter ~dst:f ~app:f ()); *)
(*   Logs.set_level (Some Logs.Debug); *)
(*   let docker () = *)
(*     Docker.create ~endpoint:(`Unix "/var/run/docker.sock")  ~config_path:None in *)

(*   (let%bind d = docker () in *)
(*   let spec = `Assoc [(`Keyword (None, "image"), `String "prepor/condo-test:good")] in *)
(*    let%map res = Docker.start d ~name:"nginx" ~spec in *)
(*    ()) |> don't_wait_for; *)
(*   never_returns (Scheduler.go ()) *)

let () =
  Ppx_inline_test_lib.Runtime.exit ()
