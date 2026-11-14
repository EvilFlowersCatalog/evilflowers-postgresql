#!/usr/bin/env bash
# Render GitHub release notes for one publishing run.
#
#   scripts/release-notes.sh <published-dir>
#
# <published-dir> holds one "<major>.txt" per published major, each containing
# "<status> <digest> <tag> <tag> ...". Environment: IMAGE, STAMP, EVENT.
set -Eeuo pipefail

dir="${1:?usage: release-notes.sh <published-dir>}"
: "${IMAGE:?}" "${STAMP:?}" "${EVENT:=push}"

case "$EVENT" in
  schedule) reason="Scheduled weekly rebuild (base image and Debian security updates)." ;;
  workflow_dispatch) reason="Manual rebuild." ;;
  *) reason="Changes merged to main." ;;
esac

echo "## Release r${STAMP}"
echo
echo "${reason}"
echo
echo "| Major | Status | Tags | Digest |"
echo "|---|---|---|---|"
shopt -s nullglob
for f in "$dir"/*.txt; do
  major="$(basename "$f" .txt)"
  read -r status digest tags < "$f"
  tag_list=""
  for t in $tags; do tag_list+="\`${t##*:}\` "; done
  echo "| ${major} | ${status} | ${tag_list} | \`${digest}\` |"
done
echo
echo "### Contents"
echo
echo "- pgvector $(jq -r '.pgvector' versions.json) (built from source)"
echo "- ParadeDB pg_search $(jq -r '.pg_search' versions.json) (upstream release package, AGPL-3.0); not in: $(jq -r '[.majors | to_entries[] | select(.value.pg_search == false) | .key] | if length == 0 then "none" else join(", ") end' versions.json)"
echo "- PGDG extensions: $(jq -r '.majors as $ms | .extensions | map(. as $e | "postgresql-<major>-" + $e
  + ([$ms | to_entries[] | select(.value[$e] == false) | .key] | if length == 0 then "" else " (not in: " + join(", ") + ")" end)) | join(", ")' versions.json)"
if jq -e '.extensions | index("age")' versions.json >/dev/null; then
  echo "- Apache AGE is also in \`\$libdir/plugins/\`: a non-superuser role loads it with \`LOAD '\$libdir/plugins/age'\` or \`session_preload_libraries = '\$libdir/plugins/age'\` (\`LOAD 'age'\` needs a superuser); grants in README.md"
fi
echo "- Full-text search dictionaries (Slovak \`sk_sk\`, Czech \`cs_cz\`): $(jq -r '.dictionaries.hunspell | join(", ")' versions.json) from Debian trixie, stop lists from $(jq -r '[.dictionaries.stopwords[] | split("@") | .[0] + "@" + .[1][0:7]] | join(", ")' versions.json)"
echo "- Base images:"
jq -r '.majors | to_entries[] | "  - \(.key): `\(.value.base)`"' versions.json
echo
echo "Exact package versions are in \`/usr/share/evilflowers/manifest.txt\` inside each image."
echo
echo "### Verify"
echo
echo '```shell'
echo "cosign verify ${IMAGE}:<tag> \\"
echo "  --certificate-identity-regexp '^https://github.com/${GITHUB_REPOSITORY:-OWNER/REPO}/' \\"
echo "  --certificate-oidc-issuer https://token.actions.githubusercontent.com"
echo '```'
echo
echo "Pin deployments to the immutable \`<minor>-${STAMP}\` tag (or the digest)."
