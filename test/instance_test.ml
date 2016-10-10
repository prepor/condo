open! Core.Std
open! Async.Std
open! Import

module I = Instance

let wait_for_a_stable = wait_for_a_stable "condo_spec"

let wait_for_a_try_again_next = wait_for_a_try_again_next "condo_spec"

let write_spec = write_spec "/tmp/condo_spec"

let%expect_test "basic" =
  let snapshot = I.init_snaphot () in
  let%bind s = system () in
  let%bind () = write_spec "prepor/condo-test:good" in
  let inst = I.create s ~spec:"/tmp/condo_spec" ~snapshot in
  let%bind () = wait_for_a_stable "prepor/condo-test:good" in
  let%bind () = write_spec "prepor/condo-test:good2" in
  let%bind () = wait_for_a_stable "prepor/condo-test:good2" in
  let%bind () = write_spec "prepor/condo-test:bad" in
  let%bind () = after (Time.Span.of_int_sec 5) in
  let%bind () = wait_for_a_try_again_next "prepor/condo-test:bad" in
  let%bind () = write_spec "prepor/condo-test:good" in
  let%bind () = wait_for_a_stable "prepor/condo-test:good" in
  let%bind () = I.stop inst in
  [%expect {|
    test.native: [INFO] Can't read state file, initialized new one
    test.native: [INFO] New instance from /tmp/condo_spec with state Init
    test.native: [INFO] Pulling image prepor/condo-test:good
    test.native: [INFO] [condo_spec] New state: (Wait
     ((id .+) (regexp)
      (spec
       ((deploy (After 1))
        (spec (Assoc (((Keyword (() image)) (String prepor/condo-test:good)))))
        (health_timeout 10) (stop_timeout 10)))))
    test.native: [INFO] [condo_spec] New state: (Stable
     ((id .+) (regexp)
      (spec
       ((deploy (After 1))
        (spec (Assoc (((Keyword (() image)) (String prepor/condo-test:good)))))
        (health_timeout 10) (stop_timeout 10)))))
    test.native: [INFO] Pulling image prepor/condo-test:good2
    test.native: [INFO] [condo_spec] New state: (WaitNext
     (((id .+) (regexp)
       (spec
        ((deploy (After 1))
         (spec (Assoc (((Keyword (() image)) (String prepor/condo-test:good)))))
         (health_timeout 10) (stop_timeout 10))))
      ((id .+) (regexp)
       (spec
        ((deploy (After 1))
         (spec (Assoc (((Keyword (() image)) (String prepor/condo-test:good2)))))
         (health_timeout 10) (stop_timeout 10))))))
    test.native: [INFO] [condo_spec] New state: (Stable
     ((id .+) (regexp)
      (spec
       ((deploy (After 1))
        (spec (Assoc (((Keyword (() image)) (String prepor/condo-test:good2)))))
        (health_timeout 10) (stop_timeout 10)))))
    test.native: [INFO] Pulling image prepor/condo-test:bad
    test.native: [INFO] [condo_spec] New state: (WaitNext
     (((id .+) (regexp)
       (spec
        ((deploy (After 1))
         (spec (Assoc (((Keyword (() image)) (String prepor/condo-test:good2)))))
         (health_timeout 10) (stop_timeout 10))))
      ((id .+) (regexp)
       (spec
        ((deploy (After 1))
         (spec (Assoc (((Keyword (() image)) (String prepor/condo-test:bad)))))
         (health_timeout 10) (stop_timeout 10))))))
    test.native: [INFO] [condo_spec] New state: (TryAgainNext
     (((id .+) (regexp)
       (spec
        ((deploy (After 1))
         (spec (Assoc (((Keyword (() image)) (String prepor/condo-test:good2)))))
         (health_timeout 10) (stop_timeout 10))))
      ((deploy (After 1))
       (spec (Assoc (((Keyword (() image)) (String prepor/condo-test:bad)))))
       (health_timeout 10) (stop_timeout 10))
      .+)) (regexp)
    test.native: [INFO] Pulling image prepor/condo-test:good
    test.native: [INFO] [condo_spec] New state: (WaitNext
     (((id .+) (regexp)
       (spec
        ((deploy (After 1))
         (spec (Assoc (((Keyword (() image)) (String prepor/condo-test:good2)))))
         (health_timeout 10) (stop_timeout 10))))
      ((id .+) (regexp)
       (spec
        ((deploy (After 1))
         (spec (Assoc (((Keyword (() image)) (String prepor/condo-test:good)))))
         (health_timeout 10) (stop_timeout 10))))))
    test.native: [INFO] [condo_spec] New state: (Stable
     ((id .+) (regexp)
      (spec
       ((deploy (After 1))
        (spec (Assoc (((Keyword (() image)) (String prepor/condo-test:good)))))
        (health_timeout 10) (stop_timeout 10)))))
    test.native: [INFO] [condo_spec] Stop
    test.native: [INFO] [condo_spec] New state: Init |}]
