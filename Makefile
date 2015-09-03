VERSION = $(shell git show HEAD:Version | tr -d "\n")
PROJECT := condo
ARTIFACT := $(PROJECT)-$(VERSION)-linux.tar.gz

build:
	go build

linux:
	env GOOS=linux GOARCH=amd64 go build -o $(PROJECT)

archive:

	tar -cvzf $(ARTIFACT) $(PROJECT)

tag:
	git tag $(VERSION)

push-tag:
	git push origin $(VERSION):$(VERSION)

push-release:
	git show -s --format=%s%b > .release_notes
	hub release create -a $(ARTIFACT) -f .release_notes $(VERSION)
	rm .release_notes

release: clean linux archive tag push-tag push-release

clean:
	rm -f ./condo
	rm -rf ./condo-*

.PHONY: build
