open Core.Std
open Async.Std

module NodeRecord = Syncer.NodeRecord

let new_nodes memory nodes =
  let is_new_node {Consul.CatalogNode.address} =
    List.Assoc.mem memory address |> not in
  List.filter nodes ~f:is_new_node

let deleted_nodes memory nodes =
  let is_deleted_node (ip, _) =
    List.find nodes ~f:(fun {Consul.CatalogNode.address} -> address = ip) |> function
    | Some _ -> false
    | None -> true in
  List.filter memory ~f:is_deleted_node

let remove_assoc l keys =
  List.fold keys ~init:l ~f:(fun l k -> List.Assoc.remove l k)

let create_nodes consul consul_prefix nodes =
  let rec adder node =
    let path = (Filename.concat consul_prefix (fst node)) in
    let body = (NodeRecord.to_yojson (snd node) |> Yojson.Safe.to_string) in
    L.info "Add node %s with body %s" path body;
    Consul.put consul ~path ~body >>= function
    | Error err ->
      L.error "Error while creating key %s in consul: %s" path (Utils.of_exn err);
      after (Time.Span.of_int_sec 1) >>= fun () ->
      adder node
    | Ok () -> return ()
  in
  List.map nodes ~f:adder |> Deferred.all_ignore

let receive_info aws catalog_nodes =
  let ips = List.map catalog_nodes ~f:(fun {Consul.CatalogNode.address} -> address) in
  L.info "Receive info from AWS about [%s]" (String.concat ~sep:", " ips);
  let rec recieve () =
    Aws.describe_instances aws ips >>= function
    | Error err ->
      L.error "Error while AWS describe instances request: %s" (Utils.of_exn err);
      after (Time.Span.of_int_sec 3) >>= fun () ->
      recieve ()
    | Ok instances ->
      L.error "-----INSTANCES! %d" (List.length instances);
      return instances in
  recieve () >>| List.map ~f:(fun {Aws.Instance.private_ip; tags} ->
      L.error "----NODE RECORD: %s" (NodeRecord.show {NodeRecord.ip = private_ip;
                                                      tags = tags;});
      (private_ip,
       {NodeRecord.ip = private_ip;
        tags = tags;}))


let delete_nodes consul consul_prefix nodes =
  let rec remover node =
    let path = (Filename.concat consul_prefix (fst node)) in
    L.info "Delete node %s" path;
    Consul.delete consul ~path >>= function
    | Error err ->
      L.error "Error while deleting key %s in consul: %s" path (Utils.of_exn err);
      after (Time.Span.of_int_sec 1) >>= fun () ->
      remover node
    | Ok () -> return () in
  List.map nodes ~f:remover |> Deferred.all_ignore

let watcher ~aws ~consul ~consul_prefix memory nodes =
  new_nodes memory nodes |> receive_info aws >>= fun new_nodes_info ->
  create_nodes consul consul_prefix new_nodes_info >>= fun () ->
  let deleted = deleted_nodes memory nodes in
  deleted |> delete_nodes consul consul_prefix >>| fun () ->
  new_nodes_info @ (remove_assoc memory (List.map deleted ~f:fst))

let sync consul aws consul_prefix =
  let (nodes, closer) = Consul.catalog_nodes consul in
  Pipe.fold nodes ~init:[] ~f:(watcher ~aws ~consul ~consul_prefix) |> Deferred.ignore |> don't_wait_for;
  closer
