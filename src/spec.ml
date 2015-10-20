type image = {
  name : string;
  tag : string [@default "latest"];
} [@@deriving yojson, show]

type env = {
  name : string;
  value : string;
} [@@deriving yojson, show]

type discovery = {
  service : string;
  tag : string option [@default None];
  multiple : bool [@default false];
  env : string;
} [@@deriving yojson, show]

type volume = {
  from : string [@key "From"];
  to_ : string [@key "To"];
} [@@deriving yojson, show]

type logs = {
  log_type : string [@key "type"];
  config : Yojson.Safe.json option [@key "Config"] [@default None] [@opaque];
} [@@deriving yojson, show]

type check = {
  script : string;
  interval : int;
  timeout : int;
} [@@deriving yojson, show]

type service = {
  name : string;
  check : check;
  port : int;
  tags : string list [@default []];
  host_port : int option [@default None];
  udp : bool [@default false]
} [@@deriving yojson, show]

type t = {
  image : image;
  discoveries : discovery list [@default []];
  services : service list [@default []];
  volumes : volume list [@default []];
  cmd : string list [@default []];
  envs : env list [@default []];
  name : string option [@default None];
  host : string option [@default None];
  user : string option [@default None];
  privileged : bool [@default false];
  network_mode : string option [@default None];
  stop_before : bool [@default false];
  stop_after_timeout : int option [@default Some 10];
  kill_timeout : int option [@default Some 10];
  logs : logs option [@default None]
} [@@deriving yojson, show]
