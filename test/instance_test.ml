open! Core.Std
open! Async.Std
open! Import

module I = Instance

let system () =
  let%bind _ = try_with (fun () -> Unix.unlink "/tmp/condo_state") in
  System.create
    ~docker_endpoint:(`Inet ("localhost", 3375))
    ~docker_config:None
    ~prefixes:["/tmp/condo_specs"]
    ~state_path:"/tmp/condo_state"

type state = (string * Sexp.t) list [@@deriving sexp]


let wait_for image spec_extract =
  let inspect_state state =
    match List.Assoc.find (state |> Sexp.of_string |> state_of_sexp) "condo_spec" with
    | Some v ->
        let spec = spec_extract (I.snapshot_of_sexp v) in
        (match spec with
        | Some spec -> if image = Edn.Util.(spec.Spec.spec |> member (`Keyword (None, "image")) |> to_string)
            then `Complete ()
            else `Continue ()
        | None -> `Continue ())
    | None -> `Continue () in
  let tick () =
    match%map try_with (fun () -> Reader.file_contents "/tmp/condo_state") with
    | Ok v -> inspect_state v
    | Error _ -> `Continue () in
  let wrapped () = tick () |> Cancellable.defer in
  Cancellable.(
    let waiter = worker ~timeout:200 ~tick:wrapped () in
    let timeout = after (Time.Span.of_int_sec 30) |> defer in
    choose [
      waiter --> (fun () -> ());
      timeout --> (fun () -> failwith "Can't wait for a stable");
    ])


let wait_for_a_stable image =
  wait_for image (function
    | Stable {spec} -> Some spec
    | _ -> None)

let wait_for_a_try_again_next image =
  wait_for image (function
    | TryAgainNext (_, spec,_) -> Some spec
    | _ -> None)


let write_spec image =
  let spec = `Assoc [(`Keyword (None, "spec")),
                     `Assoc [(`Keyword (None, "image"), `String image)];
                     (`Keyword (None, "deploy")),
                     `Vector [(`Keyword (None, "after")); `Int 1]] in
  Writer.save "/tmp/condo_spec" (Edn.to_string spec)

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
  [%expect {|
    test.native: [INFO] Can't read state file, initialized new one
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
      1475853423.2911789))
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
        (health_timeout 10) (stop_timeout 10))))) |}]
