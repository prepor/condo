#!/usr/bin/env sh
set -e

echo "--> Installing dependency manager..."
go get github.com/tools/godep

echo "--> Vendoring..."
godep restore
