open Async.Std

val create : ?advertiser:Consul.Advertiser.t -> consul:Consul.t -> docker:Docker.t -> host:string -> spec:string -> (unit -> unit Deferred.t)
