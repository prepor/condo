#!/usr/bin/env sh
set -e

echo "--> Installing dependency manager..."
curl https://glide.sh/get | sh


echo "--> Vendoring..."
glide install

