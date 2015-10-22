open Core.Std
open Async.Std

module A = Async.Std

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

  type http_method = Get | Post | Delete | Put

  (* let simple : 'a. ?req:http_method -> *)
  (*   ?parser:(Yojson.Basic.json -> 'a) -> Uri.t -> ('a, exn) Result.t A.Deferred.t = *)
  (*   fun ?(req=Get) ?parser uri -> *)
  (*   let parser = match parser with Some v -> v | None -> fun _ -> () in *)
  (*   let parse body = Result.try_with (fun () -> parser (Yojson.Basic.from_string body)) |> return in *)
  (*   let req_f = Cohttp_async.Client.(match req with *)
  (*       | Get -> fun uri -> get uri *)
  (*       | Post -> fun uri -> post uri *)
  (*       | Delete -> fun uri -> delete uri *)
  (*       | Put -> fun uri -> put uri) in *)
  (*   let do_req () = req_f uri in *)
  (*   try_with do_req >>=? not_200_as_error >>=? (fun (resp, body) -> *)
  (*       Cohttp_async.Body.to_string body >>= parse) *)

  let simple ?(req=Get) ?body ~parser uri =
    let parse body = Result.try_with (fun () -> parser (Yojson.Basic.from_string body)) |> return in
    let req_f = Cohttp_async.Client.(match req with
        | Get -> fun uri -> get uri
        | Post -> fun uri ->
          let body' = match body with
            | Some v -> Some (Cohttp_async.Body.of_string v) | None -> None in
          post ?body:body' uri
        | Delete -> fun uri -> delete uri
        | Put -> fun uri -> put uri) in
    let do_req () = req_f uri in
    try_with do_req >>=? not_200_as_error >>=? (fun (resp, body) ->
        Cohttp_async.Body.to_string body >>= parse)

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

  let rec dummy_reader r =
    Pipe.read r >>= function
    | `Eof -> return ()
    | `Ok _ -> dummy_reader r
end

module RunMonitor = struct
  type t = Monitor of (unit Ivar .t * (bool ref))

  let create () = (Monitor (Ivar.create (), ref true))

  let completed (Monitor (v, _)) = Ivar.fill v ()

  let is_running (Monitor (_, is_running)) = !is_running = true

  let close (Monitor (v, is_running)) = is_running := false; Ivar.read v

  let closer m = fun _ -> close m
end

let of_exn exn = exn |> sexp_of_exn |> Sexp.to_string_hum

let random_str length =
  let buf = Bigbuffer.create length in
  let gen_char () = (match Random.int(26 + 26 + 10) with
      |  n when n < 26 -> int_of_char 'a' + n
      | n when n < 26 + 26 -> int_of_char 'A' + n - 26
      | n -> int_of_char '0' + n - 26 - 26)
                    |> char_of_int in
  for i = 0 to length do
    Bigbuffer.add_char buf (gen_char ())
  done;
  Bigbuffer.contents buf

(* let d = *)
(*   Utils.Deferred.all_or_error [(after (Time.Span.of_int_sec 5) >>| fun _ -> Error "oops"); *)
(*                                (after (Time.Span.of_int_sec 10) >>| fun _ -> Error "oops long"); *)
(*                                (after (Time.Span.of_int_sec 3) >>| fun _ -> Ok "yep!")] *)
