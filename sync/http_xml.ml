open Core.Std
open Async.Std

let simple_builder handler ~parser =
  let parse = function
    | "" -> Result.try_with (fun () -> parser (Xml.parse_string "<root/>"))
    | body -> Result.try_with (fun () -> parser (Xml.parse_string body)) in

  let do_req uri res = try_with res >>=? Utils.HTTP.not_200_as_error >>= function
    | Error err ->
      L.error "Request %s failed: %s" (Uri.to_string uri) (Utils.of_exn err);
      Error err |> return
    | Ok (resp, body) ->
      L.debug "Request %s success: %s"
        (Uri.to_string uri) (Cohttp.Response.sexp_of_t resp |> Sexp.to_string_hum);
      Utils.HTTP.body_empty (Cohttp.Response.status resp) body >>| function
      | `Empty -> parse ""
      | `Body s -> parse s in
  handler do_req

let get_handler cont ?headers uri =
  cont uri (fun () -> Cohttp_async.Client.get ?headers uri)

let get ~parser = simple_builder get_handler ~parser
