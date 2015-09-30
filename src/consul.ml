open Lwt
open Cohttp
open Cohttp_lwt_unix

type t = { endpoint: string;
           endpoint_uri: Uri.t }

module DiscoveryResp = struct
  type node = { node : string [@key "Node"];
                address : string [@key "Address"] }
    [@@deriving yojson, show]
  type service = { port : int [@key "Port"] }
    [@@deriving yojson, show]
  type pair = { node : node [@key "Node"];
                service : service [@key "Service"] }
    [@@deriving yojson, show]
  type t = pair list
    [@@deriving yojson, show]
end

let create endpoint = { endpoint = endpoint;
                        endpoint_uri = Uri.of_string endpoint }

let uri ?(query_params = []) t path =
  (Uri.with_path t.endpoint_uri path |> Uri.with_query) query_params

let parse_discovery_body body =
  let to_res pair = DiscoveryResp.(pair.node.address, pair.service.port) in
  body |> Cohttp_lwt_body.to_string >|= fun body ->
  Yojson.Safe.from_string body
  |> DiscoveryResp.of_yojson
  |> function
  | `Ok json -> Some (List .map to_res json)
  | `Error _ -> None

let parse_kv_body body = Cohttp_lwt_body.to_string body >|= fun s -> Some s

let get_loop parser uri push =
  print_endline "Get loop tick";
  let rec loop index =
    let uri2 = match index with
      | Some index2 -> Uri.with_query uri [("index",[index2])]
      | None -> uri in
    print_endline ("Get loop tick2" ^ Uri.to_string uri2);
    Client.get uri2 >>= fun (resp, body) ->
    print_endline "Client resp";
    match Response.status resp with
    | #Code.success_status ->
      let index2 = Header.get (Response.(resp.headers)) "x-consul-index" in
      parser body >>= (function
          | Some parsed ->
            parsed |> push#push >>= fun _ -> loop index2
          | None -> print_endline "Error in parsing"; loop index)
    | _ -> print_endline "Error in request"; loop index in
  loop None

(* let discovery_loop t service push = *)
(*   discovery_loop2 (uri t ("/v1/health/service/" ^ service)) push *)

let watch_uri t parser uri =
  let (stream, push) = Lwt_stream.create_bounded 1 in
  let loop = get_loop parser uri push in
  (stream, fun () -> cancel loop)

let key t k =
  let uri = uri t ("/v1/kv/" ^ k) in
  Uri.with_query uri [("raw", [])] |> watch_uri t parse_kv_body

(* let discovery t service = *)
(*   let (stream, push) = Lwt_stream.create_bounded 1 in *)
(*   let loop = discovery_loop t service push in *)
(*   (stream, fun () -> cancel loop) *)
