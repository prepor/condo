open! Core.Std
open! Async.Std
open! Import

module D = Docker

let docker () =
  D.create ~endpoint:(`Inet ("localhost", 3375))
    (* (`Unix "/var/run/docker.sock") *)  ~config_path:None

let%expect_test "test config" =
  let%bind docker = D.create
      ~endpoint:(`Inet ("localhost", 2375))
      ~config_path:(Some "test/docker_config.json") in
  [%expect {| Docker config loaded from test/docker_config.json: ((docker.infra.aidbox.io ((username aidbox) (password hello)))) |}]

let start_and_wait image =
  let%bind d = docker () in
  let spec = `Assoc ["Image", `String image] in
  let%bind res = D.start d ~name:"nginx" ~spec in
  print_s [%message "result" ~_:(res:(D.id,string) Result.t)];
  let%map res = D.wait_healthchecks d (Result.ok_or_failwith res) ~timeout:3 in
  print_s [%message "result" ~_:(res:[`Passed | `Not_passed])]

let%expect_test "start container" =
  let%bind () = start_and_wait "prepor/condo-test:good" in
  [%expect {|
    Pulling image prepor/condo-test:good
    (result
     (Ok .+)) (regexp)
    (result Passed) |}]

let%expect_test "start container with bad health" =
  let%bind () = start_and_wait "prepor/condo-test:bad" in
  [%expect {|
    Pulling image prepor/condo-test:bad
    (result
     (Ok .+)) (regexp)
    (result Not_passed) |}]
