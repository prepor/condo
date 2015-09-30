type image = {
  name : string [@key "Name"];
  tag : string [@key "Tag"];
} [@@deriving yojson, show]

type env = {
  key : string [@key "Key"];
  value : string [@key "Value"]
} [@@deriving yojson, show]

type discovery = {
  service : string [@key "Service"];
  tag : string [@key "Tag"];
  multiple : bool [@key "Multiple"];
  env : string [@key "Env"];
} [@@deriving yojson, show]

type spec = {
  image : image [@key "Image"];
  envs : env list [@key "Envs"];
  discoveries : discovery list [@key "Discoveries"];
} [@@deriving yojson, show]

