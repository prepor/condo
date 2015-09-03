FROM golang:1.5

ENV DISTRIBUTION_DIR /go/src/github.com/prepor/condo

WORKDIR $DISTRIBUTION_DIR
COPY . $DISTRIBUTION_DIR

RUN go build
