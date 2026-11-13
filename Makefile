# Local equivalents of the CI steps. Requires docker (with buildx) and jq.
#
#   make build            # default major from versions.json, native arch
#   make test MAJOR=17
#   make lint scan

MAJOR      ?= $(shell jq -r .default versions.json)
BASE_IMAGE := $(shell jq -r --arg m "$(MAJOR)" '.majors[$$m].base' versions.json)
PGVECTOR   := $(shell jq -r .pgvector versions.json)
# empty for a major marked "pg_search": false
PG_SEARCH  := $(shell jq -r --arg m "$(MAJOR)" 'if .majors[$$m].pg_search == false then "" else .pg_search end' versions.json)
# without the extensions this major opts out of ("<extension>": false)
EXTENSIONS := $(shell jq -r --arg m "$(MAJOR)" '.majors[$$m] as $$v | .extensions | map(select($$v[.] != false)) | join(" ")' versions.json)
TAG        ?= evilflowers-postgresql:$(MAJOR)-local
TRIVY      ?= aquasec/trivy:0.76.1

.PHONY: build test scan lint shell clean

build:
	docker buildx build --load \
		--build-arg BASE_IMAGE="$(BASE_IMAGE)" \
		--build-arg PGVECTOR_VERSION="$(PGVECTOR)" \
		--build-arg PG_SEARCH_VERSION="$(PG_SEARCH)" \
		--build-arg EXTENSIONS="$(EXTENSIONS)" \
		-t $(TAG) .

test: build
	tests/smoke.sh $(TAG) "$(PGVECTOR)" "$(PG_SEARCH)" "$(EXTENSIONS)"

scan: build
	docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
		-v "$(CURDIR)/.trivyignore.yaml:/.trivyignore.yaml:ro" $(TRIVY) image \
		--scanners vuln --ignore-unfixed --ignorefile /.trivyignore.yaml \
		--severity HIGH,CRITICAL $(TAG)

lint:
	docker run --rm -i -v "$(CURDIR)/.hadolint.yaml:/.config/hadolint.yaml:ro" hadolint/hadolint:v2.15.1 < Dockerfile
	shellcheck tests/*.sh initdb/*.sh scripts/*.sh
	docker run --rm -v "$(CURDIR):/repo" -w /repo rhysd/actionlint:1.7.12 -color
	jq -e '.default as $$d | .majors[$$d].status == "stable"' versions.json >/dev/null

shell: build
	docker run --rm -it -e POSTGRES_PASSWORD=postgres --shm-size=256m $(TAG)

clean:
	-docker image rm $(TAG)
