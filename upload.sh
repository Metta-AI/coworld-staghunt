#!/usr/bin/env bash
# Build and push the Stag Hunt tools image (grader + reporter) to GHCR.
#
# The Coworld runner pulls this image on demand to run the grader / reporter
# declared in coworld_manifest.json. One image, two entrypoints.
#
# Usage:
#   ./upload.sh [VERSION] [options]
#
# VERSION  Optional extra tag, e.g. 0.1.0 (also pushes :latest). Default: latest only.
#
# Options:
#   --platform=P   Target platform(s) for buildx (default: linux/amd64).
#   --login        Log in to GHCR first via `gh auth token` (needs write:packages).
#   --no-push      Build only; do not push.
#   -h, --help     Show this help.
#
# Prereqs: docker (with buildx), and either an existing `docker login ghcr.io`
# or `gh` authed with the write:packages scope (see --login).
set -Eeuo pipefail
cd "$(dirname "$0")"

IMAGE="ghcr.io/malcolmocean/bitworld-stag-hunt-tools"
PKG="bitworld-stag-hunt-tools"
OWNER="malcolmocean"
PLATFORM="linux/amd64"
VERSION=""
DO_LOGIN=0
PUSH=1

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform=*) PLATFORM="${1#*=}";;
    --login)      DO_LOGIN=1;;
    --no-push)    PUSH=0;;
    -h|--help)    sed -n '2,21p' "$0"; exit 0;;
    --*)          die "unknown flag: $1";;
    *)
      [[ -z "$VERSION" ]] || die "only one VERSION argument is supported"
      VERSION="${1#v}"
      ;;
  esac
  shift
done

command -v docker >/dev/null || die "docker not found"
docker buildx version >/dev/null 2>&1 || die "docker buildx not available"

if [[ "$DO_LOGIN" -eq 1 ]]; then
  command -v gh >/dev/null || die "gh not found (needed for --login)"
  log "Logging in to ghcr.io as $OWNER via gh token"
  gh auth token | docker login ghcr.io -u "$OWNER" --password-stdin \
    || die "ghcr login failed — does your gh token have write:packages? Try: gh auth refresh -h github.com -s write:packages"
fi

TAGS=(-t "${IMAGE}:latest")
[[ -n "$VERSION" ]] && TAGS+=(-t "${IMAGE}:${VERSION}")

PUSH_FLAG="--push"
[[ "$PUSH" -eq 0 ]] && PUSH_FLAG="--load"

log "Building ${IMAGE} (${PLATFORM}) ${VERSION:+version $VERSION }${PUSH_FLAG}"
docker buildx build --platform "$PLATFORM" -f Dockerfile.tools "${TAGS[@]}" "$PUSH_FLAG" .

[[ "$PUSH" -eq 0 ]] && { log "Built (not pushed)."; exit 0; }

log "Pushed ${IMAGE}:latest${VERSION:+ and :$VERSION}"

# The runner can only pull a public package (or one it's been granted access to).
# GitHub has no REST endpoint to flip visibility, so we just report + point at
# the settings page when it's still private.
if command -v gh >/dev/null; then
  vis=$(gh api "user/packages/container/${PKG}" --jq '.visibility' 2>/dev/null || echo "unknown")
  if [[ "$vis" == "public" ]]; then
    log "Package visibility: public ✓"
  else
    log "Package visibility: ${vis}. Make it public so the Coworld runner can pull it:"
    printf '    https://github.com/users/%s/packages/container/%s/settings\n' "$OWNER" "$PKG"
  fi
fi
