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

let () =
  Ppx_inline_test_lib.Runtime.exit ()
