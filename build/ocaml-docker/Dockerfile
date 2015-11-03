FROM ubuntu:14.04

RUN apt-get update && apt-get install -y wget m4 make gcc unzip patch rsync ocaml-nox aspcud
RUN wget https://github.com/ocaml/opam/releases/download/1.2.2/opam-1.2.2-x86_64-Linux -O /usr/bin/opam
RUN chmod +x /usr/bin/opam
RUN opam init -y
RUN opam switch 4.02.3

RUN eval `opam config env` && \
    opam install -y oasis
