open Lwt
type reason

type deploy =
  { spec: Spec.spec;
    created_at: float;
    mutable container: string option;
    mutable checks: string list;
    mutable stable: bool; }

type state =
  { last_stable: deploy option;
    current: deploy option;
    next: deploy option;}

type t =
  { mutable state: state}

let create () =
  let s = { last_stable = None; current = None; next = None; } in
  { state = s }

let wait_discovery discovery =
  

let wait_discoveries discoveries = Lwt_list.map_p wait_discovery discoveries

let start deploy =
  let%lwt discoveries = wait_discoveries deploy.spec.discoveries


let stop deploy = ()

let deploy t spec reason =
  match t.state.next with
  | Some next -> stop next
  | None -> ();
    let next = { spec = spec;
                 container = None;
                 checks = [];
                 created_at = Unix.time ();
                 stable = false } in
    start next;
    t.state <- {t.state with next = Some next };
