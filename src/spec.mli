type image = {
  name : string;
  tag : string;
}

type env = {
  key : string;
  value : string;
}

type discovery = {
  service : string;
  tag : string;
  multiple : bool;
  env : string;
}

type spec = {
  image : image;
  envs : env list;
  discoveries : discovery list;
}

val show_spec : spec -> bytes

val spec_of_yojson : Yojson.Safe.json -> [ `Error of bytes | `Ok of spec ]
