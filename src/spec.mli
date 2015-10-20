type image = { name : bytes; tag : bytes; }
val image_to_yojson : image -> Yojson.Safe.json
val image_of_yojson :
  Yojson.Safe.json -> [ `Error of bytes | `Ok of image ]
val pp_image : Format.formatter -> image -> unit
val show_image : image -> bytes
type env = { name : bytes; value : bytes; }
val env_to_yojson : env -> Yojson.Safe.json
val env_of_yojson : Yojson.Safe.json -> [ `Error of bytes | `Ok of env ]
val pp_env : Format.formatter -> env -> unit
val show_env : env -> bytes
type discovery = {
  service : bytes;
  tag : bytes option;
  multiple : bool;
  env : bytes;
}
val discovery_to_yojson : discovery -> Yojson.Safe.json
val discovery_of_yojson :
  Yojson.Safe.json -> [ `Error of bytes | `Ok of discovery ]
val pp_discovery : Format.formatter -> discovery -> unit
val show_discovery : discovery -> bytes
type volume = { from : bytes; to_ : bytes; }
val volume_to_yojson : volume -> Yojson.Safe.json
val volume_of_yojson :
  Yojson.Safe.json -> [ `Error of bytes | `Ok of volume ]
val pp_volume : Format.formatter -> volume -> unit
val show_volume : volume -> bytes
type logs = { log_type : bytes; config : Yojson.Safe.json option; }
val logs_to_yojson : logs -> Yojson.Safe.json
val logs_of_yojson :
  Yojson.Safe.json -> [ `Error of bytes | `Ok of logs ]
val pp_logs : Format.formatter -> logs -> unit
val show_logs : logs -> bytes
type check = { script : bytes; interval : int; timeout : int; }
val check_to_yojson : check -> Yojson.Safe.json
val check_of_yojson :
  Yojson.Safe.json -> [ `Error of bytes | `Ok of check ]
val pp_check : Format.formatter -> check -> unit
val show_check : check -> bytes
type service = {
  name : bytes;
  check : check;
  port : int;
  tags : bytes list;
  host_port : int option;
  udp : bool;
}
val service_to_yojson : service -> Yojson.Safe.json
val service_of_yojson :
  Yojson.Safe.json -> [ `Error of bytes | `Ok of service ]
val pp_service : Format.formatter -> service -> unit
val show_service : service -> bytes
type t = {
  image : image;
  discoveries : discovery list;
  services : service list;
  volumes : volume list;
  cmd : bytes list;
  envs : env list;
  name : bytes option;
  host : bytes option;
  user : bytes option;
  privileged : bool;
  network_mode : bytes option;
  stop_before : bool;
  stop_after_timeout : int option;
  kill_timeout : int option;
  logs : logs option;
}
val to_yojson : t -> Yojson.Safe.json
val of_yojson : Yojson.Safe.json -> [ `Error of bytes | `Ok of t ]
val pp : Format.formatter -> t -> unit
val show : t -> bytes
