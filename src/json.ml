module SerializedState = struct
  module Deploy = struct
    type t = {
      image: Spec.Image.t;
      created_at: float;
      stable_at: float option;
    } [@@deriving yojson, show]
  end
  type t = {
    current: Deploy.t option;
    next: Deploy.t option;
    last_stable: Spec.Image.t option;
  } [@@deriving yojson, show]
end
