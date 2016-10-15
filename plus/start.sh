#!/bin/bash

# Envs:
# - CONSUL_ENDPOINT like 127.0.0.1:8500
# - CONDO_ARGS additional args for condo
# - MULTI_CT_ARGS additional args for multi-consul-template

set -e

prefixes=
for i in "$@"; do
    prefixes="$prefixes $i:/var/lib/condo"
done

cat > /var/lib/condo/consul-template.conf <<EOF
consul = "$CONSUL_ENDPOINT"

EOF

multi-consul-template -c /var/lib/condo/consul-template.conf --consul-endpoint tcp://$CONSUL_ENDPOINT $MULTI_CT_ARGS $prefixes &

exec condo /var/lib/condo /var/lib/condo -s /var/lib/condo/state --server 80 --consul-endpoint tcp://$CONSUL_ENDPOINT $CONDO_ARGS
