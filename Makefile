
OCB_FLAGS = -tag bin_annot -use-ocamlfind -tag thread
OCB = ocamlbuild $(OCB_FLAGS)

condo:
	$(OCB) -I src condo.byte

condo_native:
	$(OCB) -I src condo.native
