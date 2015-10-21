module Image :
sig
  type t = { name : string; tag : string; }
  val to_yojson : t -> Yojson.Safe.json
  val of_yojson : Yojson.Safe.json -> [ `Error of string | `Ok of t ]
  val pp : Format.formatter -> t -> unit
  val show : t -> string
end
module Env :
sig
  type t = { name : string; value : string; }
  val to_yojson : t -> Yojson.Safe.json
  val of_yojson : Yojson.Safe.json -> [ `Error of string | `Ok of t ]
  val pp : Format.formatter -> t -> unit
  val show : t -> string
end
module Discovery :
sig
  type t = {
    service : string;
    tag : string option;
    multiple : bool;
    env : string;
  }
  val to_yojson : t -> Yojson.Safe.json
  val of_yojson : Yojson.Safe.json -> [ `Error of string | `Ok of t ]
  val pp : Format.formatter -> t -> unit
  val show : t -> string
end
module Volume :
sig
  type t = { from : string; to_ : string; }
  val to_yojson : t -> Yojson.Safe.json
  val of_yojson : Yojson.Safe.json -> [ `Error of string | `Ok of t ]
  val pp : Format.formatter -> t -> unit
  val show : t -> string
end
module Logs :
sig
  type t = { log_type : string; config : Yojson.Safe.json option; }
  val to_yojson : t -> Yojson.Safe.json
  val of_yojson : Yojson.Safe.json -> [ `Error of string | `Ok of t ]
  val pp : Format.formatter -> t -> unit
  val show : t -> string
end
module Check :
sig
  type t = { script : string; interval : int; timeout : int; }
  val to_yojson : t -> Yojson.Safe.json
  val of_yojson : Yojson.Safe.json -> [ `Error of string | `Ok of t ]
  val pp : Format.formatter -> t -> unit
  val show : t -> string
end
module Service :
sig
  type t = {
    name : string;
    check : Check.t;
    port : int;
    tags : string list;
    host_port : int option;
    udp : bool;
  }
  val to_yojson : t -> Yojson.Safe.json
  val of_yojson : Yojson.Safe.json -> [ `Error of string | `Ok of t ]
  val pp : Format.formatter -> t -> unit
  val show : t -> string
end
type t = {
  image : Image.t;
  discoveries : Discovery.t list;
  services : Service.t list;
  volumes : Volume.t list;
  cmd : string list;
  envs : Env.t list;
  name : string option;
  host : string option;
  user : string option;
  privileged : bool;
  network_mode : string option;
  stop_before : bool;
  stop_after_timeout : int option;
  kill_timeout : int option;
  logs : Logs.t option;
}
val to_yojson : t -> Yojson.Safe.json
val of_yojson : Yojson.Safe.json -> [ `Error of string | `Ok of t ]
val pp : Format.formatter -> t -> unit
val show : t -> string
