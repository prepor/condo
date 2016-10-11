#!/usr/bin/env ocaml
#use "topfind"
#require "topkg"
open Topkg

let () =
  let build = (Pkg.build ~cmd:(fun c os files ->
      OS.Cmd.run @@ Cmd.(Pkg.build_cmd c os
                         % "-plugin-tag"
                         % "package(ppx_driver.ocamlbuild)"
                         %% of_list files)) ()) in
  Pkg.describe "condo" ~build @@ fun c ->
  Ok [ Pkg.bin "src/condo" ~dst:"condo";
       Pkg.test (* ~exts:(Exts.ext ".byte") ~auto:false *) ~args:Cmd.(v "inline-test-runner" % "condo") "test/test"; ]
