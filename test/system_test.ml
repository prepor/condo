open! Core.Std
open! Async.Std
open! Import

module S = System

let%expect_test "place snapshot" =
  let snapshot = Instance.init_snaphot () |> Instance.snapshot_to_yojson in
  let%bind s = system () in
  let%bind () = S.place_snapshot s ~name:"nginx" ~snapshot in
  print_endline (In_channel.read_all "/tmp/condo_state");
  [%expect {|
    Can't read state file, initialized the new one
    [["nginx",["Init"]]] |}]
