#!/bin/bash

set -ex

mkdir -p release

oasis2opam --local -y

TAG=`oasis query version`
SHA=`git rev-parse --short HEAD`

git tag $TAG
git push -f origin $TAG

docker build -t condo:$TAG ./

VERSION="$TAG ($SHA)"

CONTAINER=`docker run -e VERSION=$VERSION condo:$VERSION`

docker cp $CONTAINER:/opt/condo/condo.native release/condo_${TAG}-x86_64_linux
docker cp $CONTAINER:/opt/condo/condo_monitoring.native release/condo_monitorin_${TAG}-x86_64_linux

make clean
VERSION=$VERSION make

cp condo.native release/condo_${TAG}-x86_64_osx
cp condo_monitoring.native release/condo_monitorin_${TAG}-x86_64_osx

pushd monitoring-ui
lein cljsbuild once prod
cp -r resources/public/static/vendor out/
cp resources/public/static/index.html out/
popd

cp -r monitoring-ui/out release/ui
tar -zcvf release/ui_${TAG}.tar.gz release/ui

git show -s --format=%s%b > .release_notes
hub release create \
    -f .release_notes $TAG \
    -a release/condo_${TAG}-x86_64_linux \
    -a release/condo_monitorin_${TAG}-x86_64_linux \
    -a release/condo_${TAG}-x86_64_osx \
    -a release/condo_monitorin_${TAG}-x86_64_osx \
    -a release/ui_${TAG}.tar.gz

rm .release_notes
