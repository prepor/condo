open! Core.Std
open! Async.Std
open! Import

module C = Cancel
let%expect_test "defer" =
  let v = Ivar.create () in
  let c = C.defer (Ivar.read v) in
  let%bind () = C.cancel c "cancel!" in
  let%bind res = C.wait c in
  print_s [%message "result" ~_:(res : [`Result of string | `Cancelled of string])];
  [%expect {| (result (Cancelled cancel!)) |}] >>= fun () ->
  let v = Ivar.create () in
  let c = C.defer (Ivar.read v) in
  Ivar.fill v "value";
  let%bind res = C.wait c in
  print_s [%message "result" ~_:(res : [`Result of string | `Cancelled of unit])];
  [%expect {| (result (Result value)) |}]

let%expect_test "choose" =
  let v1 = Ivar.create () in
  let v2 = Ivar.create () in
  let c1 = C.defer (Ivar.read v1) in
  let c2 = C.defer (Ivar.read v2) in
  let res = C.choose
      [C.choice c1 (fun v -> `Res1 v);
       C.choice c2 (fun v -> `Res2 v)] in
  Ivar.fill v2 "value2";
  let%bind res' = res in
  print_s [%message "result" ~_:(res' : [`Res1 of string | `Res2 of string])];
  [%expect {| (result (Res2 value2)) |}]

let%expect_test "worker" =
  let tick i =
    (if i < 5 then `Continue (i + 1)
     else `Complete i)
    |> return
    |> C.defer in
  let w = C.worker ~tick:tick 0 in
  let%bind res = C.wait w in
  print_s [%message "result" ~_:(res : [`Result of int | `Cancelled of unit])];
  [%expect {| (result (Result 5)) |}] >>= fun () ->

  let tick i =
    let cancellable signal =
      print_s [%message "int" (i:int)];
      if i < 3 then `Continue (i + 1) |> return
      else choose [choice (never ()) (fun _ -> `Complete (-1));
                   choice signal (fun s -> print_s [%message "stop signal" (s:string)]; `Complete (-1))] in
    C.wrap cancellable in
  let w = C.worker ~tick:tick 0 in
  let%bind () = Scheduler.yield () in
  let%bind () = C.cancel w "oops" in
  let%bind res = C.wait w in
  print_s [%message "result" ~_:(res : [`Result of int | `Cancelled of string])];
  [%expect {|
      (int (i 0))
      (int (i 1))
      (int (i 2))
      (int (i 3))
      ("stop signal" (s oops))
      (result (Result -1)) |}] >>= fun () ->

  let tick i =
    print_s [%message "int" (i:int)];
    (if i < 3 then `Continue (i + 1) |> return
     else never ())
    |> C.defer in
  let w = C.worker ~tick:tick 0 in
  let%bind () = Scheduler.yield () in
  let%bind () = C.cancel w "oops" in
  let%bind res = C.wait w in
  print_s [%message "result" ~_:(res : [`Result of int | `Cancelled of string])];
  [%expect {|
    (int (i 0))
    (int (i 1))
    (int (i 2))
    (int (i 3))
    (result (Cancelled oops)) |}]
