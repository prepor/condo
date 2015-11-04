#!/bin/bash

set -ex

mkdir -p release
rm -rf release/*

TAG=`oasis query version`
SHA=`git rev-parse --short HEAD`
VERSION="$TAG ($SHA)"

git tag -f $TAG
git push -f origin $TAG

docker build -t condo:$TAG ./

CONTAINER=`docker run -d -e "VERSION=$VERSION" condo:$TAG`
docker wait $CONTAINER

docker cp $CONTAINER:/opt/condo/_build/src/condo.native release/condo_${TAG}-x86_64_linux
docker cp $CONTAINER:/opt/condo/_build/monitoring/condo_monitoring.native release/condo_monitoring_${TAG}-x86_64_linux

make clean
VERSION=${VERSION} make

cp condo.native release/condo_${TAG}-x86_64_osx
cp condo_monitoring.native release/condo_monitoring_${TAG}-x86_64_osx

pushd monitoring-ui
lein cljsbuild once prod
cp -r resources/public/static/vendor out/
cp resources/public/static/index.html out/
popd

cp -r monitoring-ui/out release/ui
tar -zcvf release/ui_${TAG}.tar.gz -C release/ui .

git show -s --format=%s%b > .release_notes
hub release create \
    -f .release_notes $TAG \
    -a release/condo_${TAG}-x86_64_linux \
    -a release/condo_monitoring_${TAG}-x86_64_linux \
    -a release/condo_${TAG}-x86_64_osx \
    -a release/condo_monitoring_${TAG}-x86_64_osx \
    -a release/ui_${TAG}.tar.gz

rm .release_notes

# RELEASE=`curl -u "prepor" -X POST -H "Content-Type: application/json" -d "{\"tag_name\": \"$TAG\"}" https://api.github.com/repos/prepor/condo/releases | jq '.id'`

# # curl -u "prepor" -X DELETE https://api.github.com/repos/prepor/condo/releases/$RELEASE

# curl -X POST -H "Content-Type: application/octet-stream" --data "@release/ui_${TAG}.tar.gz" https://uploads.github.com/repos/prepor/condo/releases/$RELEASE/assets?name=ui_${TAG}.tar.gz

