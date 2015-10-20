open Core.Std
open Async.Std

module Deferred = struct
  let all_or_error' deferreds =
    Deferred.all deferreds >>| fun results ->
    match (List.find results (function | Ok _ -> false; | Error _ -> true)) with
    | Some (Error e) -> Error e
    | None -> Ok (List.map results (function | Ok v -> v; | Error _ -> assert false))
    | Some _ -> assert false

  (* val all_or_error : ('a, 'b) Result.t Deferred.t list -> ('a list, 'b) Result.t Deferred.t *)
  let all_or_error deferreds =
    let error = Ivar.create () in
    let results = List.map deferreds
        (fun d -> d >>| function | Ok v -> Ok v
                                 | Error err -> Ivar.fill_if_empty error (Error err); (Error err)) in
    let results' = all_or_error' results in
    choose [choice (error |> Ivar.read) Fn.id;
            choice results' Fn.id]
end

let of_exn exn = exn |> sexp_of_exn |> Sexp.to_string_hum

(* let d = *)
(*   Utils.Deferred.all_or_error [(after (Time.Span.of_int_sec 5) >>| fun _ -> Error "oops"); *)
(*                                (after (Time.Span.of_int_sec 10) >>| fun _ -> Error "oops long"); *)
(*                                (after (Time.Span.of_int_sec 3) >>| fun _ -> Ok "yep!")] *)
