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

module HTTP = struct
  exception BadStatus of Cohttp.Code.status_code
  let not_200_as_error (resp, body) =
    let r = match Cohttp.Response.status resp with
      | #Cohttp.Code.success_status -> Ok (resp, body)
      | status -> Error (BadStatus status) in
    return r
end

module Pipe = struct
  let to_lines r =
    let buf = Bigbuffer.create 16 in
    let rec worker w =
      let detect_line s =
        let n = String.length s in
        let rec tick pos =
          if n = 0 || pos = n then
            return ()
          else
          if s.[pos] = '\n' then
            Pipe.write w (Bigbuffer.contents buf) >>=
            (fun () -> Bigbuffer.clear buf; tick (pos + 1))
          else
          if s.[pos] = '\r' && pos + 1 < n && s.[pos + 1] = '\n' then
            Pipe.write w (Bigbuffer.contents buf)
            >>= (fun () -> Bigbuffer.clear buf; tick (pos + 2))
          else
            (Bigbuffer.add_char buf s.[pos];
             tick (pos + 1)) in
        tick 0 in
      Pipe.read r >>= function
      | `Eof -> return ()
      | `Ok v -> detect_line v >>= fun () -> worker w in
    Pipe.init worker
end

let of_exn exn = exn |> sexp_of_exn |> Sexp.to_string_hum

(* let d = *)
(*   Utils.Deferred.all_or_error [(after (Time.Span.of_int_sec 5) >>| fun _ -> Error "oops"); *)
(*                                (after (Time.Span.of_int_sec 10) >>| fun _ -> Error "oops long"); *)
(*                                (after (Time.Span.of_int_sec 3) >>| fun _ -> Ok "yep!")] *)
