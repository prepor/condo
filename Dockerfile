FROM gliderlabs/alpine:3.4

ADD pkg/condo_linux_amd64 /usr/bin/condo

VOLUME ["/var/lib/condo"]

ENTRYPOINT ["condo"]

CMD ["start", "--directory", "/var/lib/condo"]