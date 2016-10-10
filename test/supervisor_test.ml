open! Core.Std
open! Async.Std
open! Import

module S = Supervisor

let%expect_test "basic" =
  let%bind _ = try_with (fun () -> Unix.unlink "/tmp/condo_specs/spec1.edn") in
  let%bind _ = try_with (fun () -> Unix.unlink "/tmp/condo_specs/spec2.edn") in
  let%bind system = system () in
  let t = S.create ~system ~prefixes:["/tmp/condo_specs"] in
  let%bind () = write_spec "/tmp/condo_specs/spec1.edn" "prepor/condo-test:good" in
  let%bind () = wait_for_a_stable "spec1" "prepor/condo-test:good" in
  let%bind () = write_spec "/tmp/condo_specs/spec2.edn" "prepor/condo-test:good" in
  let%bind () = wait_for_a_stable "spec2" "prepor/condo-test:good" in
  let%bind () = Unix.unlink "/tmp/condo_specs/spec1.edn" in
  let%bind () = wait_for_a_init "spec1" in
  let%bind () = write_spec "/tmp/condo_specs/spec1.edn" "prepor/condo-test:good" in
  let%bind () = wait_for_a_stable "spec1" "prepor/condo-test:good" in
  let%bind () = S.stop t in
  [%expect {|
    test.native: [INFO] Can't read state file, initialized new one
    test.native: [INFO] New instance from /tmp/condo_specs/spec1.edn with state Init
    test.native: [INFO] Pulling image prepor/condo-test:good
    test.native: [INFO] [spec1] New state: (Wait
     ((id .+) (regexp)
      (spec
       ((deploy (After 1))
        (spec (Assoc ((image (String prepor/condo-test:good)))))
        (health_timeout 10) (stop_timeout 10)))))
    test.native: [INFO] [spec1] New state: (Stable
     ((id .+) (regexp)
      (spec
       ((deploy (After 1))
        (spec (Assoc ((image (String prepor/condo-test:good)))))
        (health_timeout 10) (stop_timeout 10)))))
    test.native: [INFO] New instance from /tmp/condo_specs/spec2.edn with state Init
    test.native: [INFO] Pulling image prepor/condo-test:good
    test.native: [INFO] [spec2] New state: (Wait
     ((id .+) (regexp)
      (spec
       ((deploy (After 1))
        (spec (Assoc ((image (String prepor/condo-test:good)))))
        (health_timeout 10) (stop_timeout 10)))))
    test.native: [INFO] [spec2] New state: (Stable
     ((id .+) (regexp)
      (spec
       ((deploy (After 1))
        (spec (Assoc ((image (String prepor/condo-test:good)))))
        (health_timeout 10) (stop_timeout 10)))))
    test.native: [INFO] [spec1] Stop
    test.native: [INFO] [spec1] New state: Init
    test.native: [INFO] New instance from /tmp/condo_specs/spec1.edn with state Init
    test.native: [INFO] Pulling image prepor/condo-test:good
    test.native: [INFO] [spec1] New state: (Wait
     ((id .+) (regexp)
      (spec
       ((deploy (After 1))
        (spec (Assoc ((image (String prepor/condo-test:good)))))
        (health_timeout 10) (stop_timeout 10)))))
    test.native: [INFO] [spec1] New state: (Stable
     ((id .+) (regexp)
      (spec
       ((deploy (After 1))
        (spec (Assoc ((image (String prepor/condo-test:good)))))
        (health_timeout 10) (stop_timeout 10)))))
    test.native: [INFO] [spec1] Stop
    test.native: [INFO] [spec1] New state: Init
    test.native: [INFO] [spec2] Stop
    test.native: [INFO] [spec2] New state: Init |}]
