open! Core.Std
open! Async.Std

type deploy_strategy = Before | After of int [@@deriving sexp, yojson]

type json = [ `Assoc of (string * json) list
            | `Bool of bool
            | `Float of float
            | `Int of int
            | `List of json list
            | `Null
            | `String of string ] [@@deriving sexp]

module Json = struct
  include Yojson.Safe

  let json_to_yojson v = v
  let json_of_yojson v = Ok v

  let json_of_sexp v = (json_of_sexp v :> Yojson.Safe.json)

  let sexp_of_json v = sexp_of_json (Yojson.Safe.to_basic v)

end

type t = {
  deploy : deploy_strategy;
  spec : Json.json;
  health_timeout : int;
  stop_timeout : int;
} [@@deriving yojson, sexp]

let int_field v k ~default =
  match Edn.Util.(v |> member (`Keyword (None, k))) with
  | `Int v -> Ok v
  | `Null -> Ok default
  | _ -> Error (sprintf "`%s` should be integer" k)

let parse_spec v =
  let open Result.Let_syntax in
  let%bind spec = match Edn.Util.(v |> member (`Keyword (None, "spec"))) with
  | `Assoc _ as spec -> Ok spec
  | _ -> Error "`spec` keyword with map is required" in
  let deploy' = Edn.Util.(v |> member (`Keyword (None, "deploy"))) in
  let%bind health_timeout = int_field v "health-timeout" ~default:10 in
  let%bind stop_timeout = int_field v "stop-timeout" ~default:10 in
  let%map deploy = match deploy' with
  | `Null -> Ok Before
  | `Vector [`Keyword (None, "After"); `Int timeout] -> Ok (After timeout)
  | `Vector [`Keyword (None, "Before")] -> Ok Before
  | _ -> Error "`deploy` option should be [:Before] or [:After timeout] where timeout is number of seconds before previous container termination" in
  {deploy; health_timeout; stop_timeout;
  spec = (Edn.Json.to_json spec :> Yojson.Safe.json); }

let from_file path =
  match%map try_with ~extract_exn:true (fun () -> Reader.file_contents path
                                         >>| Edn.from_string
                                         >>| parse_spec ) with
  | Ok v -> v |> Result.map_error ~f:(fun e -> Failure (sprintf "Bad specification %s: %s" path e))
  | Error e -> Error e
