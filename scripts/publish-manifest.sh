#!/usr/bin/env bash
# Combine per-architecture digests into one multi-arch manifest and tag it.
#
#   scripts/publish-manifest.sh <digest-dir>
#
# Environment: IMAGE, STAMP, MAJOR, STATUS (from the workflow); reads versions.json.
# Writes "digest" and "tags" (space separated) to $GITHUB_OUTPUT.
#
# Tag scheme (see docs/release-cycle.md):
#   stable / maintenance : <minor>-<stamp>  <minor>  <major>  [latest if default major]
#   preview              : <minor>-<stamp>  <minor>  <major>-preview
set -Eeuo pipefail

dir="${1:?usage: publish-manifest.sh <digest-dir>}"
: "${IMAGE:?}" "${STAMP:?}" "${MAJOR:?}" "${STATUS:?}"

base="$(jq -r --arg m "$MAJOR" '.majors[$m].base' versions.json)"
default="$(jq -r '.default' versions.json)"

# postgres:18.6-trixie@sha256:... -> 18.6 ; postgres:19rc1-trixie@... -> 19rc1
tag="${base#*:}"
tag="${tag%%@*}"
minor="${tag%%-*}"

shopt -s nullglob
digests=("$dir"/*)
if (( ${#digests[@]} != 2 )); then
  echo "expected 2 platform digests for PostgreSQL $MAJOR, found ${#digests[@]}" >&2
  exit 1
fi

tags=("${IMAGE}:${minor}-${STAMP}" "${IMAGE}:${minor}")
case "$STATUS" in
  stable|maintenance)
    tags+=("${IMAGE}:${MAJOR}")
    if [[ "$MAJOR" == "$default" ]]; then tags+=("${IMAGE}:latest"); fi
    ;;
  preview)
    tags+=("${IMAGE}:${MAJOR}-preview")
    ;;
  *)
    echo "unknown status '$STATUS' for PostgreSQL $MAJOR" >&2
    exit 1
    ;;
esac

args=()
for t in "${tags[@]}"; do args+=(-t "$t"); done
sources=()
for f in "${digests[@]}"; do sources+=("${IMAGE}@sha256:$(basename "$f")"); done

docker buildx imagetools create "${args[@]}" "${sources[@]}"
docker buildx imagetools inspect "${tags[0]}"

digest="$(docker buildx imagetools inspect "${tags[0]}" --format '{{json .Manifest}}' | jq -r '.digest')"

{
  echo "digest=${digest}"
  echo "tags=${tags[*]}"
} >> "${GITHUB_OUTPUT:-/dev/stdout}"
