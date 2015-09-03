build:
	go build

linux:
	env GOOS=linux GOARCH=amd64 go build

.PHONY: build
