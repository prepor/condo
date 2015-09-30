type t

type change = { key: string;
                before: string option;
                after: string option; }

type reason =
  | Init | ParamsChange of change list | DiscoveryChange of change

val create : unit -> t

val deploy :  t -> Spec.spec -> reason -> unit

val stop_all : t -> unit
