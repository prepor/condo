let () =
  Ocamlbuild_plugin.dispatch (fun hook ->
      Ppx_driver_ocamlbuild.dispatch hook)
