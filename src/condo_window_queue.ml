open! Core.Std
open! Async.Std

type 'a t = {
  size : int;
  queue : 'a Queue.t;
  mutable current_read : 'a Ivar.t option;
}

let create ~size =
  {size; queue = Queue.create ~capacity:size (); current_read = None}

let read t =
  if Option.is_some t.current_read then raise (Invalid_argument "Concurrent reads are denied");
  match Queue.dequeue t.queue with
  | Some v -> return v
  | None ->
      let i = Ivar.create () in
      t.current_read <- Some i;
      Ivar.read i

let write t v =
  if Queue.length t.queue >= t.size then
    Queue.dequeue_exn t.queue |> ignore;
  match t.current_read with
  | Some i ->
      Ivar.fill i v;
      t.current_read <- None
  | None ->
      Queue.enqueue t.queue v
