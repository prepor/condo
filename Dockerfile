FROM gliderlabs/alpine:3.4

ADD ./pkg/linux_amd64/condo /usr/bin/condo

VOLUME ["/var/lib/condo"]

ENTRYPOINT ["condo"]

CMD ["start", "--directory", "/var/lib/condo"]