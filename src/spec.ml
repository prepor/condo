module Image = struct
  type t = {
    name : string;
    tag : string [@default "latest"];
  } [@@deriving yojson, show]
end

module Env = struct
  type t = {
    name : string;
    value : string;
  } [@@deriving yojson, show]
end

module Discovery = struct
  type t = {
    service : string;
    tag : string option [@default None];
    multiple : bool [@default false];
    env : string;
  } [@@deriving yojson, show]
end

module Volume = struct
  type t = {
    from : string [@key "From"];
    to_ : string [@key "To"];
  } [@@deriving yojson, show]
end

module Logs = struct
  type t = {
    log_type : string [@key "type"];
    config : Yojson.Safe.json option [@key "Config"] [@default None] [@opaque];
  } [@@deriving yojson, show]
end

module Check = struct
  type t = {
    script : string;
    interval : int;
    timeout : int;
  } [@@deriving yojson, show]
end

module Service = struct
  type t = {
    name : string;
    check : Check.t;
    port : int;
    tags : string list [@default []];
    host_port : int option [@default None];
    udp : bool [@default false]
  } [@@deriving yojson, show]
end

type t = {
  image : Image.t;
  discoveries : Discovery.t list [@default []];
  services : Service.t list [@default []];
  volumes : Volume.t list [@default []];
  cmd : string list [@default []];
  envs : Env.t list [@default []];
  name : string option [@default None];
  host : string option [@default None];
  user : string option [@default None];
  privileged : bool [@default false];
  network_mode : string option [@default None];
  stop_before : bool [@default false];
  stop_after_timeout : int option [@default Some 10];
  kill_timeout : int option [@default Some 10];
  logs : Logs.t option [@default None]
} [@@deriving yojson, show]
