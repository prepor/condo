open! Core.Std
open! Async.Std

type ('a, 'b) t = { deferred: [`Cancelled of 'b | `Result of 'a] Deferred.t;
                    canceller: ('b -> unit Deferred.t) }

let create source ~canceller =
  let res = Ivar.create () in
  let wrapped_canceller v =
    Ivar.fill_if_empty res (`Cancelled v);
    canceller v in
  Deferred.upon source (fun v -> Ivar.fill_if_empty res (`Result v));
  {deferred = Ivar.read res; canceller = wrapped_canceller}

let wrap f =
  let cancelled = Ivar.create () in
  let finished = Ivar.create () in
  let deferred =
    let%map res = f (Ivar.read cancelled) in
    Ivar.fill finished ();
    `Result res in
  let canceller v =
    Ivar.fill_if_empty cancelled v;
    Ivar.read finished in
  {deferred; canceller}

let wait {deferred} = deferred

exception Unexpected_cancel
let wait_exn t =
  match%map wait t with
  | `Result v -> v
  | `Cancelled v -> raise Unexpected_cancel

let cancel {canceller} v = canceller v

let defer d = create d ~canceller:(fun _ -> return ())

let defer_wait d = wrap (fun _ -> d)

type 'a choice = Choice : ('c, unit) t * ('c -> 'a) -> 'a choice

let choose l =
  let f (Choice (c, f)) = choice (wait c) (function
    | `Result v -> f v
    | `Cancelled () -> failwith "Should not be cancelled outside of choose") in
  let choices = List.map ~f l in
  let%bind res = choose choices in
  let%map () = Deferred.List.iter ~f:(fun (Choice (c, _)) -> cancel c ()) l in
  res

let choice t f = Choice (t, f)
let ( --> ) t f = Choice (t, f)

module M = struct
  type ('a,'b) parent = ('a, 'b) t
  type ('a,'b) t = ('a,'b) parent

  let bind t f =
    let canceller = ref (fun v -> cancel t v) in
    let deferred = match%bind (wait t) with
    | `Cancelled v ->
        `Cancelled v |> return
    | `Result v -> let t' = (f v) in
        canceller := (fun v -> cancel t' v);
        let%map res = (wait t') in
        res in
    {deferred; canceller = (fun v -> !canceller v)}

  let return v = create (return v) ~canceller:(fun _ -> return ())

  let map = `Define_using_bind
end

include Monad.Make2 (M)

(* cancel guarantees that last tick had finished *)
let worker ?sleep ~tick init_state =
  let rec worker_tick state =
    let open Let_syntax in
    match%bind (tick state) with
    | `Complete v ->
        return v
    | `Continue v ->
        let%bind () = match sleep with
        | Some v -> after (Time.Span.of_ms (float_of_int v)) |> defer
        | None -> return () in
        worker_tick v in
  worker_tick init_state

let wrap_tick f =
  let wrapped v = f v |> defer in
  wrapped
