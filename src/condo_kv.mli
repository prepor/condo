open! Async.Std
module type KV = sig
  val put : key:string -> data:string -> unit
  val get_all : ?prefix:string -> unit -> ((string * string) list, string) Deferred.Result.t
end

val consul : endpoint:Async_http.addr -> prefix:string -> (module KV)
