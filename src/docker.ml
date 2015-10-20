open Core.Std
open Async.Std

type t = { endpoint: Uri.t }

type container = Id of string | Name of string

let container_to_string = function
  | Id v -> v
  | Name v -> v

let create endpoint = { endpoint = Uri.of_string endpoint }

(* let rename docker name =  *)

let start docker spec = Error (Failure "foo") |> return

let stop docker container = Error (Failure "foo") |> return

let rm docker container = Error (Failure "foo") |> return

