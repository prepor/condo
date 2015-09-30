type t

val create : string -> t

val key : t -> string -> string Lwt_stream.t * (unit -> unit)

(* val discovery : t -> string -> string * int list Lwt_stream.t * (unit -> unit) *)
