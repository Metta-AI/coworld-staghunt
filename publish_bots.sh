#!/usr/bin/env bash
# Build and push stag_hunt bot/player images to GHCR.
#
# Each bot has its own players/<bot>/Dockerfile (build context = repo root).
# Image names use hyphens to match coworld_manifest.json's player[].image, even
# though the bot source dirs / binaries use underscores.
#
# Usage:
#   ./publish_bots.sh [bot ...]            # default: the bots not yet on GHCR
#   ./publish_bots.sh --all                # every bot in players/
#   ./publish_bots.sh --login big_game_hunter moose_hunter
#
# Options:
#   --login        Log in to GHCR via `gh auth token` first (needs write:packages).
#   --all          Build every players/<bot> with a Dockerfile.
#   --platform=P   Target platform (default: linux/amd64 — what the runner uses).
#   --no-push      Build only.
#   -h, --help     Show this help.
#
# After pushing, make each package public (GitHub has no REST API for that) with
# the making-ghcr-packages-public skill.
set -Eeuo pipefail
cd "$(dirname "$0")"

OWNER="malcolmocean"
REG="ghcr.io/${OWNER}"
PLATFORM="linux/amd64"
DO_LOGIN=0
ALL=0
PUSH=1
BOTS=()

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }

# Default set: bots whose hyphen-named image isn't on GHCR yet.
DEFAULT_BOTS=(big_game_hunter moose_hunter elephant_hunter modeler)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --login)      DO_LOGIN=1;;
    --all)        ALL=1;;
    --platform=*) PLATFORM="${1#*=}";;
    --no-push)    PUSH=0;;
    -h|--help)    sed -n '2,21p' "$0"; exit 0;;
    --*)          die "unknown flag: $1";;
    *)            BOTS+=("$1");;
  esac
  shift
done

command -v docker >/dev/null || die "docker not found"
docker buildx version >/dev/null 2>&1 || die "docker buildx not available"

if [[ "$ALL" -eq 1 ]]; then
  BOTS=()
  for d in players/*/; do
    b="$(basename "$d")"
    [[ -f "players/$b/Dockerfile" ]] && BOTS+=("$b")
  done
fi
[[ ${#BOTS[@]} -eq 0 ]] && BOTS=("${DEFAULT_BOTS[@]}")

if [[ "$DO_LOGIN" -eq 1 ]]; then
  command -v gh >/dev/null || die "gh not found (needed for --login)"
  log "Logging in to ghcr.io as $OWNER via gh token"
  gh auth token | docker login ghcr.io -u "$OWNER" --password-stdin \
    || die "ghcr login failed — try: gh auth refresh -h github.com -s write:packages"
fi

PUSH_FLAG="--push"; [[ "$PUSH" -eq 0 ]] && PUSH_FLAG="--output=type=cacheonly"

# Uses the default buildx builder (containerd image store handles single-platform
# cross-builds + push). Avoid a separate docker-container builder — its cache
# proved easy to poison across context changes (e.g. adding .dockerignore).
for bot in "${BOTS[@]}"; do
  df="players/${bot}/Dockerfile"
  [[ -f "$df" ]] || die "no Dockerfile for bot '$bot' ($df)"
  image="${REG}/bitworld-stag-hunt-${bot//_/-}:latest"   # underscores → hyphens
  log "Building ${image} (${PLATFORM}) from ${df}"
  docker buildx build --platform "$PLATFORM" -f "$df" -t "$image" "$PUSH_FLAG" .
done

[[ "$PUSH" -eq 0 ]] && { log "Built (not pushed)."; exit 0; }

log "Pushed: ${BOTS[*]}"
if command -v gh >/dev/null; then
  log "Visibility (make any 'private' ones public via the making-ghcr-packages-public skill):"
  for bot in "${BOTS[@]}"; do
    pkg="bitworld-stag-hunt-${bot//_/-}"
    vis=$(gh api "user/packages/container/${pkg}" --jq '.visibility' 2>/dev/null || echo "unknown")
    printf '    %-40s %s\n' "$pkg" "$vis"
  done
fi
