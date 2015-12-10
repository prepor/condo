open Async.Std

val start : ?advertiser:Consul.Advertiser.t -> consul:Consul.t -> docker:Docker.t -> host:string -> watcher:(module Spec.Watcher) -> unit
