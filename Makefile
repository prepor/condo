OCB_FLAGS = -use-ocamlfind -tag thread -I common
OCB = ocamlbuild $(OCB_FLAGS)

condo:
	$(OCB) -I condo condo.byte

condo_native:
	$(OCB) -I condo condo.native

monitoring:
	$(OCB) -I monitoring condo_monitoring.byte

monitoring_native:
	$(OCB) -I monitoring condo_monitoring.native

test: condo
	$(OCB) -I test test.byte && ./test.byte

.PHONY: condo condo_native monitoring monitoring_native test
