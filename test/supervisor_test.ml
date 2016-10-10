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
    Can't read state file, initialized the new one
    New instance from /tmp/condo_specs/spec1.edn with state Init
    Pulling image prepor/condo-test:good
    spec1 --> New state: (Wait
     ((id .+) (regexp)
      (spec
       ((deploy (After 1))
        (spec (Assoc ((image (String prepor/condo-test:good)))))
        (health_timeout 10) (stop_timeout 10)))))
    spec1 --> New state: (Stable
     ((id .+) (regexp)
      (spec
       ((deploy (After 1))
        (spec (Assoc ((image (String prepor/condo-test:good)))))
        (health_timeout 10) (stop_timeout 10)))))
    New instance from /tmp/condo_specs/spec2.edn with state Init
    Pulling image prepor/condo-test:good
    spec2 --> New state: (Wait
     ((id .+) (regexp)
      (spec
       ((deploy (After 1))
        (spec (Assoc ((image (String prepor/condo-test:good)))))
        (health_timeout 10) (stop_timeout 10)))))
    spec2 --> New state: (Stable
     ((id .+) (regexp)
      (spec
       ((deploy (After 1))
        (spec (Assoc ((image (String prepor/condo-test:good)))))
        (health_timeout 10) (stop_timeout 10)))))
    spec1 --> Stop
    spec1 --> New state: Init
    New instance from /tmp/condo_specs/spec1.edn with state Init
    Pulling image prepor/condo-test:good
    spec1 --> New state: (Wait
     ((id .+) (regexp)
      (spec
       ((deploy (After 1))
        (spec (Assoc ((image (String prepor/condo-test:good)))))
        (health_timeout 10) (stop_timeout 10)))))
    spec1 --> New state: (Stable
     ((id .+) (regexp)
      (spec
       ((deploy (After 1))
        (spec (Assoc ((image (String prepor/condo-test:good)))))
        (health_timeout 10) (stop_timeout 10)))))
    spec1 --> Stop
    spec1 --> New state: Init
    spec2 --> Stop
    spec2 --> New state: Init |}]
