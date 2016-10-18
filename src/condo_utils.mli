module Base64 : sig
  val decode : ?alphabet:string -> string -> string

  val encode : ?pad:bool -> ?alphabet:string -> string -> string
end

val name_from_path : string -> string

val random_str : int -> string
