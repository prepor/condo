open! Core.Std
open! Async.Std

let print_s sexp = printf "%s\n%!" (sexp |> Sexp.to_string_hum)

let () =
  (* Random.self_init (); *)
  let f = (Writer.to_formatter (Lazy.force Writer.stdout)) in
  Logs.set_reporter (Logs.format_reporter ~dst:f ~app:f ());
  (* Logs.set_level (Some Logs.Debug) *)
  Logs.Src.set_level Logs.default (Some Logs.Debug)

type edn = [
  | `Assoc of (edn * edn) list
  | `List of edn list
  | `Vector of edn list
  | `Set of edn list
  | `Null
  | `Bool of bool
  | `String of string
  | `Char of string
  | `Symbol of (string option * string)
  | `Keyword of (string option * string)
  | `Int of int
  | `BigInt of string
  | `Float of float
  | `Decimal of string
  | `Tag of (string option * string * edn) ]
[@@deriving sexp]

module System = Condo_system
module Instance = Condo_instance
module Docker = Condo_docker
module Cancel = Cancellable
module Spec = Condo_spec
module Supervisor = Condo_supervisor

let system () =
  let%bind _ = try_with (fun () -> Unix.unlink "/tmp/condo_state") in
  System.create
    ~docker_endpoint:(`Inet ("localhost", 3375))
    ~docker_config:None
    ~state_path:"/tmp/condo_state"
    ~expose_state:`No
    ~host:None

let read_state state_path =
  match%map try_with (fun () -> Reader.file_contents state_path
                       >>| Yojson.Safe.from_string
                       >>| (function | `Assoc l -> Ok l | _ -> Error "Bad state")
                       >>| Result.ok_or_failwith) with
  | Ok v -> v
  | Error e ->
      []

let wait_for name snapshot_checker =
  let inspect_state state =
    match List.Assoc.find state name with
    | Some v ->
        if snapshot_checker (Instance.snapshot_of_yojson v |> Result.ok_or_failwith) then `Complete ()
        else `Continue ()
    | None -> `Continue () in
  let tick () =
    let%map state = read_state "/tmp/condo_state" in
    inspect_state state in
  let wrapped () = tick () |> Cancel.defer in
  Cancel.(
    let waiter = worker ~sleep:200 ~tick:wrapped () in
    let timeout = after (Time.Span.of_int_sec 30) |> defer in
    choose [
      waiter --> (fun () -> ());
      timeout --> (fun () -> failwith "Can't wait for a stable");
    ])

let wait_for_image name image spec_extractor =
  let checker snapshot =
    match spec_extractor snapshot with
    | Some spec -> if
      image = Yojson.Basic.Util.(spec.Spec.spec |> member "Image" |> to_string)
        then true
        else false
    | None -> false in
  wait_for name checker

let wait_for_a_stable name image =
  wait_for_image name image (function
    | Instance.Stable {Instance.spec} -> Some spec
    | _ -> None)

let wait_for_a_try_again_next name image =
  wait_for_image name image (function
    | Instance.TryAgainNext (_, spec,_) -> Some spec
    | _ -> None)

let wait_for_a_init name =
  let checker snapshot = snapshot = Instance.Init in
  wait_for name checker

let write_spec path image =
  let spec = `Assoc [(`Keyword (None, "spec")),
                     `Assoc [(`Keyword (None, "Image"), `String image)];
                     (`Keyword (None, "deploy")),
                     `Vector [(`Keyword (None, "after")); `Int 1]] in
  Writer.save path (Edn.to_string spec)
