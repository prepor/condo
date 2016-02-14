open Core.Std

module NodeRecord = struct
  type t = {
    ip : string;
    tags : Utils.Yojson_assoc.String.t;
  } [@@deriving yojson, show]
end
