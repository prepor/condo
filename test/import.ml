open! Core.Std
open! Async.Std

let print_s sexp = printf "%s\n%!" (sexp |> Sexp.to_string_hum)

let () =
  (* Random.self_init (); *)
  let f = (Writer.to_formatter (Lazy.force Writer.stdout)) in
  Logs.set_reporter (Logs.format_reporter ~dst:f ~app:f ());
  (* Logs.set_level (Some Logs.Debug) *)
  Logs.Src.set_level Logs.default (Some Logs.Debug)

include Condo


