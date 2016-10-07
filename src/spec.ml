open! Core.Std
open! Async.Std

(* type logging = { *)
(*   driver : string; *)
(*   options : (string * string) list [@default []]; *)
(* } [@@deriving cconv, sexp] *)

(* type weight_device = { *)
(*   path : string; *)
(*   weight : string; *)
(* } [@@deriving cconv, sepx] *)

(* type rate_device = { *)
(*   path : string; *)
(*   rate : string; *)
(* } [@@deriving cconv, sexp] *)

(* type host_config = { *)
(*   binds : string list [@default []]; *)
(*   links : string list [@default []]; *)
(*   memory : int option [@default None]; *)
(*   memory_swap : int option [@default None]; *)
(*   memory_reservation : int option [@default None]; *)
(*   kernel_memory : int option [@default None]; *)
(*   CpuPercent *)
(*     CpuShares *)
(*     CpuPeriod *)
(*     CpuQuota *)
(*     CpusetCpus : string option [@default None]; *)
(*   CpusetMems : string option [@default None]; *)
(*   IOMaximumBandwidth *)
(*     IOMaximumIOps *)
(*     BlkioWeight *)
(*     BlkioWeightDevice : weight_device list [@default []]; *)
(*   BlkioDeviceReadBps : rate_device list [@default []]; *)
(*   BlkioDeviceWriteBps  : rate_device list [@default []]; *)
(*     BlkioDeviceReadIOps : rate_device list [@default []]; *)
(*     BlkioDeviceWiiteIOps : rate_device list [@default []]; *)
(*     MemorySwappiness : int option [@default None]; *)
(*     OomKillDisable : book option [@default None]; *)
(*     OomScoreAdj : int option [@default None]; *)
(*     PidMode : string option [@default None]; *)
(*     PidsLimit : int option [@default None]; *)
(*     PortBindings : (string * port_binding list) list [@default []]; *)
(*     PublishAllPorts : bool [@default false]; *)
(*     Privileged : bool [@default false]; *)
(*     ReadonlyRootfs : bool [@default false]; *)
(*     Dns : string list [@default []]; *)
(*     DnsOptions : string list [@default []]; *)
(*     DnsSearch : string list [@default []]; *)
(*     ExtraHosts : string list [@default []]; *)
(*     VolumesFrom : string list [@default []]; *)
(*     CapAdd : string list [@default []]; *)
(*     CapDrop : string list [@default []]; *)
(*     GroupAdd : string list [@default []]; *)


(* } [@@deriving cconv, sexp] *)

(* type t = { *)
(*   name : string option [@default None]; *)
(*   hostname : string option [@default None]; *)
(*   domainname : string option [@default None]; *)
(*   user : string option [@default None]; *)
(*   env : string list [@default []]; *)
(*   cmd : string list [@default []]; *)
(*   volumes : string list [@default []]; *)
(*   working_dir : string option [@default None]; *)
(*   network_disabled : bool [@default false]; *)
(*   mac_address : string option [@default None]; *)
(*   exposed_ports : string list [@default []]; *)
(*   stop_signal : string [@default "SIGTERM"]; *)

(*   host_config : host_config; *)

(*   cap_add : string list [@default []]; *)
(*   cap_drop : string list [@default []]; *)
(*   command : string list option [@default None]; *)
(*   cgroup_parent : string option [@default None]; *)
(*   devices : string list [@default []]; *)
(*   dns : string list [@default []]; *)
(*   dns_search : string list [@default []]; *)
(*   tmpfs : string list [@default []]; *)
(*   entrypoint : string list option [@default None]; *)
(*   environment : (string * string) list [@default []]; *)
(*   expose : string list [@default []]; *)
(*   extra_hosts : string list [@default []]; *)
(*   image : string; *)
(*   labels : (string * string) list [@default []]; *)
(*   links : string list [@default []]; *)
(*   logging : logging option; *)
(*   network_mode : string [@default "bridge"]; *)
(*   networks : string list [@default []]; *)
(* } [@@deriving cconv, sexp] *)

type deploy_strategy = Before | After of int [@@deriving sexp]

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

type t = {
  deploy : deploy_strategy;
  spec : edn;
  health_timeout : int;
  stop_timeout : int;
} [@@deriving sexp]

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
  let%bind stop_timeout = int_field v "health-timeout" ~default:10 in
  let%map deploy = match deploy' with
  | `Null -> Ok Before
  | `Vector [`Keyword (None, "after"); `Int timeout] -> Ok (After timeout)
  | `Vector [`Keyword (None, "before")] -> Ok Before
  | _ -> Error "`deploy` option should be [:Before] or [:After timeout] where timeout is number of seconds before previous container termination" in
  {deploy; spec; health_timeout; stop_timeout}

let from_file path =
  match%map try_with (fun () -> Reader.file_contents path >>| Edn.from_string ) with
  | Ok v -> parse_spec v |> Result.map_error ~f:(fun e -> sprintf "Bad specification %s: %s" path e)
  | Error Edn.Errors.Error v -> Error (sprintf "Bad formatted EDN in %s: %s" path v)
  | Error e -> Error (sprintf "Error while reading %s: %s" path (Exn.to_string e))
