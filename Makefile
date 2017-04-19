# Metadata about this makefile and position
MKFILE_PATH := $(lastword $(MAKEFILE_LIST))
CURRENT_DIR := $(dir $(realpath $(MKFILE_PATH)))
CURRENT_DIR := $(CURRENT_DIR:/=)

# Get the project metadata
GOVERSION := 1.8
VERSION := 0.11.rc1
PROJECT := github.com/prepor/condo
OWNER := $(dir $(PROJECT))
OWNER := $(notdir $(OWNER:/=))
NAME := $(notdir $(PROJECT))
EXTERNAL_TOOLS = 

# Current system information (this is the invoking system)
ME_OS = $(shell go env GOOS)
ME_ARCH = $(shell go env GOARCH)

# Default os-arch combination to build
XC_OS ?= darwin freebsd linux windows
XC_ARCH ?= 386 amd64
XC_EXCLUDE ?=

# GPG Signing key (blank by default, means no GPG signing)
GPG_KEY ?=

# List of tests to run
TEST ?= ./...

# List all our actual files, excluding vendor
GOFILES = $(shell go list $(TEST) | grep -v /vendor/)

# Tags specific for building
GOTAGS ?=

# Number of procs to use
GOMAXPROCS ?= 4

web:
	@echo "==> Compile ClojureScript for ${PROJECT}..."
	@$(MAKE) -C ui prod
	@echo "==> Generate ${PROJECT}..."
	@go generate

# bin builds the project by invoking the compile script inside of a Docker
# container. Invokers can override the target OS or architecture using
# environment variables.
bin:
	@echo "==> Building ${PROJECT}..."
	@docker run \
		--interactive \
		--tty \
		--rm \
		--dns=8.8.8.8 \
		--env="VERSION=${VERSION}" \
		--env="PROJECT=${PROJECT}" \
		--env="OWNER=${OWNER}" \
		--env="NAME=${NAME}" \
		--env="GOMAXPROCS=${GOMAXPROCS}" \
		--env="GOTAGS=${GOTAGS}" \
		--env="XC_OS=${XC_OS}" \
		--env="XC_ARCH=${XC_ARCH}" \
		--env="XC_EXCLUDE=${XC_EXCLUDE}" \
		--env="DIST=${DIST}" \
		--workdir="/go/src/${PROJECT}" \
		--volume="${CURRENT_DIR}:/go/src/${PROJECT}" \
		"golang:${GOVERSION}" /usr/bin/env sh -c "scripts/compile.sh"

# bin-local builds the project using the local go environment. This is only
# recommended for advanced users or users who do not wish to use the Docker
# build process.
bin-local:
	@echo "==> Building ${PROJECT} (locally)..."
	@env \
		VERSION="${VERSION}" \
		PROJECT="${PROJECT}" \
		OWNER="${OWNER}" \
		NAME="${NAME}" \
		GOMAXPROCS="${GOMAXPROCS}" \
		GOTAGS="${GOTAGS}" \
		XC_OS="${XC_OS}" \
		XC_ARCH="${XC_ARCH}" \
		XC_EXCLUDE="${XC_EXCLUDE}" \
		DIST="${DIST}" \
		/usr/bin/env sh -c "scripts/compile.sh"

# bootstrap installs the necessary go tools for development or build
bootstrap:
	@echo "==> Bootstrapping ${PROJECT}..."
	@for t in ${EXTERNAL_TOOLS}; do \
		echo "--> Installing $$t" ; \
		go get -u "$$t"; \
	done

# deps gets all the dependencies for this repository and vendors them.
deps:
	@echo "==> Updating dependencies..."
	@docker run \
		--interactive \
		--tty \
		--rm \
		--dns=8.8.8.8 \
		--env="GOMAXPROCS=${GOMAXPROCS}" \
		--workdir="/go/src/${PROJECT}" \
		--volume="${CURRENT_DIR}:/go/src/${PROJECT}" \
		"golang:${GOVERSION}" /usr/bin/env sh -c "scripts/deps.sh"

# dev builds the project for the current system as defined by go env.
dev:
	@env \
		XC_OS="${ME_OS}" \
		XC_ARCH="${ME_ARCH}" \
		$(MAKE) -f "${MKFILE_PATH}" bin
	@echo "--> Moving into bin/"
	@mkdir -p "${CURRENT_DIR}/bin/"
	@cp "${CURRENT_DIR}/pkg/${ME_OS}_${ME_ARCH}/${NAME}" "${CURRENT_DIR}/bin/"
ifdef GOPATH
	@echo "--> Moving into GOPATH/"
	@mkdir -p "${GOPATH}/bin/"
	@cp "${CURRENT_DIR}/pkg/${ME_OS}_${ME_ARCH}/${NAME}" "${GOPATH}/bin/"
endif

# docker builds the docker container
docker:
	@echo "==> Building container..."
	@docker build \
		--pull \
		--rm \
		--file="Dockerfile" \
		--tag="${OWNER}/${NAME}" \
		--tag="${OWNER}/${NAME}:${VERSION}" \
		"${CURRENT_DIR}"

# generate runs the code generator
generate:
	@echo "==> Generating ${PROJECT}..."
	@go generate ${GOFILES}

# test runs the test suite
test:
	@echo "==> Testing ${PROJECT}..."
	@go test -timeout=300s -parallel=1 -p 1 -tags="${GOTAGS}" ${GOFILES} ${TESTARGS}

# test-race runs the race checker
test-race:
	@echo "==> Testing ${PROJECT} (race)..."
	@go test -timeout=300s -parallel=1 -p 1 -race -tags="${GOTAGS}" ${GOFILES} ${TESTARGS}

release:
	@echo "==> Pushing to Docker registry..."
	@docker push "${OWNER}/${NAME}:latest"
	@docker push "${OWNER}/${NAME}:${VERSION}"
	@echo "==> Making github release..."
	@ghr "${VERSION}" pkg/

.PHONY: bin bin-local bootstrap deps dev dist docker docker-push generate test test-race release
