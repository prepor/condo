open Core.Std

(* http://docs.aws.amazon.com/general/latest/gr/sigv4_signing.html *)

let sha256 s =
  Cstruct.of_string s
  |> Nocrypto.Hash.digest `SHA256
  |> Cstruct.to_string
  |> Hex.of_string |> function `Hex s -> s

let cstruct_to_hex cs =
  cs
  |> Cstruct.to_string
  |> Hex.of_string |> function `Hex s -> s

let make_signed_headers headers =
  headers
  |> List.map ~f:(Fn.compose String.lowercase fst)
  |> List.sort ~cmp:compare
  |> String.concat ~sep:";"

(* let make_canonical_request ~metho ~uri ~headers ~payload = *)
(*   let canonical_method = Utils.HTTP.method_to_string metho in *)
(*   let canonical_path = Uri.path uri in *)
(*   let canonical_query_string = *)
(*     Uri.query uri *)
(*     |> List.sort ~cmp:(fun a b -> compare (fst a) (fst b)) *)
(*     |> List.map ~f:(fun (n, xs) -> (n, List.hd_exn xs)) *)
(*     |> List.map ~f:(fun (n, v) -> n ^ "=" ^ v) *)
(*     |> String.concat ~sep:"&" in *)
(*   let canonical_headers = *)
(*     headers *)
(*     |> List.map ~f:(fun (n, v) -> (String.lowercase n) ^ ":" ^ v ^ "\n") *)
(*     |> List.sort ~cmp: compare *)
(*     |> String.concat in *)
(*   let signed_headers = make_signed_headers headers in *)
(*   let hashed_payload = str_to_hex payload in *)
(*   let s = canonical_method ^ "\n" ^ canonical_path ^ "\n" ^ canonical_query_string ^ "\n" *)
(*           ^ canonical_headers ^ "\n" ^ signed_headers ^ "\n" ^ hashed_payload in *)
(*   print_endline s; *)
(*   (signed_headers, str_to_hex s) *)

let make_credential_scope ~time ~region ~service =
  (sprintf "%s/%s/%s/aws4_request\n" (Time.format time "%Y%m%d") region service)

(* let string_to_sign ~time ~credential_scope ~hashed_request = *)
(*   "AWS4-HMAC-SHA256\n" ^ (Time.format time "%Y%m%dT%H%M%SZ\n") *)
(*   ^ credential_scope ^ hashed_request *)

let hmac k s =
  Nocrypto.Hash.SHA256.hmac ~key:k (Cstruct.of_string s)

let make_signed_key ~secret_key ~time ~region ~service =
  let k_key = (Cstruct.of_string ("AWS4" ^ secret_key)) in
  let k_date = hmac k_key (Time.format time "%Y%m%d") in
  let k_region = hmac k_date region in
  let k_service = hmac k_region service in
  hmac k_service "aws4_request"

type t = {
  secret_key : string;
  access_key : string;
  region : string;
  service : string }

let sign_uri t ?(headers=[]) uri =
  let time = Time.now () in
  (* let time = Time.of_float 1451260800.0 in *)
  let time = Time.sub time (Time.utc_offset time Time.Zone.local) in
  let {access_key; secret_key; region; service } = t in
  let host = Uri.host uri |> function
    | Some v -> v
    | None -> raise (Invalid_argument ("Host should be in URL:" ^ (Uri.to_string uri))) in
  let credential_scope = (sprintf "%s/%s/%s/aws4_request" (Time.format time "%Y%m%d") region service) in
  let credential = access_key ^ "/" ^ credential_scope in
  let headers = ("Host", host)::headers in
  let signed_headers = make_signed_headers headers in
  let amz_date = (Time.format time "%Y%m%dT%H%M%SZ") in
  let uri' = Uri.add_query_params' uri [("X-Amz-Algorithm", "AWS4-HMAC-SHA256");
                                        ("X-Amz-Credential", credential);
                                        ("X-Amz-Date", amz_date);
                                        ("X-Amz-Expires", "30");
                                        ("X-Amz-SignedHeaders", signed_headers)] in
  let canonical_headers =
    headers
    |> List.map ~f:(fun (n, v) -> (String.lowercase n) ^ ":" ^ v ^ "\n")
    |> List.sort ~cmp: compare
    |> String.concat in
  let canonical_method = "GET" in
  let canonical_path = Uri.path uri' |> function
    | "" -> "/"
    | other -> other in
  let canonical_query_string =
    Uri.query uri'
    |> List.sort ~cmp:(fun a b -> compare (fst a) (fst b))
    |> List.map ~f:(fun (n, xs) -> (n, List.hd_exn xs))
    |> List.map ~f:(fun (n, v) ->
        let component = if n = "X-Amz-SignedHeaders" then `Query_value else `Path in
        n ^ "=" ^ (Uri.pct_encode ~component v))
    |> String.concat ~sep:"&" in
  let hashed_payload = sha256 "" in
  let canonical_request = canonical_method ^ "\n" ^ canonical_path ^ "\n" ^ canonical_query_string ^ "\n"
                          ^ canonical_headers ^ "\n" ^ signed_headers ^ "\n" ^ hashed_payload in
  let () = printf "Canonical:\n%s\n" canonical_request in
  let signing_key = make_signed_key ~secret_key ~time ~region ~service in
  let string_to_sign = "AWS4-HMAC-SHA256\n" ^ amz_date ^ "\n"
                       ^ credential_scope ^ "\n" ^ (sha256 canonical_request) in
  let () = printf "String to sign:\n%s\n" string_to_sign in
  let () = printf "Signing key:\n%s\n" (signing_key |> Cstruct.to_string |> sha256) in
  let signature = hmac signing_key string_to_sign |> cstruct_to_hex in
  Uri.add_query_param' uri' ("X-Amz-Signature", signature)


let ec2_uri t =
  Uri.make ~scheme:"http" ~host:(sprintf "ec2.%s.amazonaws.com" t.region) ~path:"/" ()

module Instance = struct
  type t = {
    private_ip : string;
    tags: (string * string) list
  } [@@deriving show]
end

let xml_match tag xml =
  if Xml.tag xml = tag then
    xml
  else
    raise (Failure (sprintf "%s doesn't match xml %s" tag (Xml.to_string_fmt xml)))

let xml_member member xml =
  List.find (Xml.children xml) ~f:(fun node -> Xml.tag node = member) |> function
  | Some v -> v
  | None -> raise (Failure (sprintf "Can't find %s in xml %s" member (Xml.to_string_fmt xml)))

let xml_member_text member xml =
  xml_member member xml |> Xml.children |> List.hd_exn |> Xml.pcdata

let describe_instances t ips =
  let list_to_filter_values filter_n l =
    List.mapi l ~f:(fun i v -> ((sprintf "Filter.%i.Value.%i" filter_n (i + 1)), v)) in
  let filters = ("Filter.1.Name", "private-ip-address")::
                (list_to_filter_values 1 ips) in
  let uri =
    Uri.add_query_params' (ec2_uri t) (("Action", "DescribeInstances")::
                                       ("Version", "2015-10-01")
                                       ::filters) in
  let parser v =
    L.error "---AWS PARSE! %s" (Xml.to_string_fmt v);
    v
    |> xml_match "DescribeInstancesResponse"
    |> xml_member "reservationSet"
    |> Xml.fold (fun res reservation ->
        reservation
        |> xml_match "item"
        |> xml_member "instancesSet"
        |> Xml.fold (fun res' instance ->
            xml_match "item" instance |> ignore;
            let private_ip = instance |> xml_member_text "privateIpAddress" in
            let tags =
              instance
              |> xml_match "item"
              |> xml_member "tagSet"
              |> Xml.map (fun tag ->
                  xml_match "item" tag |> ignore;
                  (xml_member_text "key" tag, xml_member_text "value" tag)) in
            {Instance.private_ip = private_ip;
             tags = tags}::res') res) [] in
  Http_xml.get ~parser (sign_uri t uri)
  (* Ok (List.map ips ~f:(fun ip -> *)
  (*     {Instance.private_ip = ip; *)
  (*      tags = [("role", "megaboom")]})) |> Async.Std.return *)

let create ~secret_key ~access_key ~region ~service = {secret_key; access_key; region; service}
