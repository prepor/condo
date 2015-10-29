open Core.Std
open Async.Std
open Cohttp
open Cohttp_async

module AS = Cohttp_async.Server

let create port =
  let callback ~body _a _req =
    AS.respond_with_string ~code:`OK "Condo is alive!\n" in
  L.info "Start server on %i" port;
  AS.create (Tcp.on_port port) callback >>| fun _ -> ()

