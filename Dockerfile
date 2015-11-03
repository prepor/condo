FROM prepor/ocaml:4.02.3

ADD opam /opt/opam
ADD _oasis /opt/opam/_oasis
WORKDIR /opt/opam

RUN eval `opam config env` && opam pin add -y condo-deps .

ADD . /opt/condo
WORKDIR /opt/condo

CMD bash -c 'eval `opam config env` && opam pin add -y condo . && ./configure && make'


