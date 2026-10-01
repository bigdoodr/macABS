#!/usr/bin/env bash
#
# build-abs-payload.sh <abs-tag>      e.g.  scripts/build-abs-payload.sh v2.37.1
#
# Builds the downloadable Audiobookshelf "payload" that installed copies of
# macABS fetch (see macABS/ABSUpdater.swift):
#
#   1. Reads the Node major the ABS tag itself uses from its Dockerfile, and
#      picks the newest darwin-arm64 build of that major. The payload ships
#      its OWN Node, so an ABS release that raises its Node requirement (v2.37.0
#      went to Node 24) needs no macABS app rebuild.
#   2. Runs vendor-audiobookshelf.sh with those versions (clone, npm ci,
#      TypeScript build if the tag has one, client build, ffmpeg/ffprobe).
#   3. Ad-hoc signs node, ffmpeg/ffprobe and every native module. Apple
#      Silicon refuses to run unsigned arm64 code.
#   4. Launches the result and requires /healthcheck to pass. If that
#      fails, nothing is published.
#   5. Writes payload-out/{abs-payload-<tag>-darwin-arm64.tar.gz, manifest.json}.
#
# Must run on an Apple Silicon Mac (the GitHub macos-15 runner is one).

set -euo pipefail

ABS_TAG="${1:?usage: build-abs-payload.sh <abs-tag, e.g. v2.37.1>}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-${ROOT}/payload-out}"
WORK="$(mktemp -d)"
SMOKE_PORT="${SMOKE_PORT:-13399}"
ARCH="darwin-arm64"
ASSET="abs-payload-${ABS_TAG}-${ARCH}.tar.gz"

log() { echo "[payload] $*"; }
trap 'if [ -n "${SERVER_PID:-}" ]; then kill "${SERVER_PID}" 2>/dev/null || true; fi' EXIT

# --- 1. Which Node does this ABS release use? -------------------------------
dockerfile="$(curl -fsSL "https://raw.githubusercontent.com/advplyr/audiobookshelf/${ABS_TAG}/Dockerfile")"
node_major="$(printf '%s\n' "${dockerfile}" | sed -n 's/^FROM .*node:\([0-9][0-9]*\).*/\1/p' | head -1)"
if [ -z "${node_major}" ]; then
    echo "ERROR: could not read a 'FROM node:<major>' line from ${ABS_TAG}'s Dockerfile." >&2
    echo "       Refusing to guess a Node version; fix build-abs-payload.sh for the new layout." >&2
    exit 1
fi
node_version="$(curl -fsSL https://nodejs.org/dist/index.json \
    | jq -r --arg prefix "v${node_major}." \
        '[.[] | select(.version | startswith($prefix)) | select(.files | index("osx-arm64-tar"))][0].version' \
    | sed 's/^v//')"
if [ -z "${node_version}" ] || [ "${node_version}" = "null" ]; then
    echo "ERROR: no darwin-arm64 Node ${node_major}.x found on nodejs.org." >&2
    exit 1
fi
log "ABS ${ABS_TAG} -> Node ${node_version} (major ${node_major} per its Dockerfile)"

# --- 2. Build ---------------------------------------------------------------
VENDOR="${WORK}/Vendor"
VENDOR_DIR="${VENDOR}" NODE_VERSION="${node_version}" ABS_REF="${ABS_TAG}" "${ROOT}/vendor-audiobookshelf.sh"

NODE_BIN="${VENDOR}/node/bin/node"
ABS_DIR="${VENDOR}/audiobookshelf"
ENTRY="$("${NODE_BIN}" -e 'console.log(require(process.argv[1]).entry)' "${ABS_DIR}/macabs-payload.json")"

# --- 3. Ad-hoc sign everything executable -----------------------------------
log "Ad-hoc signing node, ffmpeg/ffprobe and native modules"
codesign --force --sign - --entitlements "${ROOT}/node-entitlements.plist" "${NODE_BIN}"
for bin in "${ABS_DIR}/ffmpeg" "${ABS_DIR}/ffprobe"; do
    [ -f "${bin}" ] && codesign --force --sign - "${bin}"
done
while IFS= read -r -d '' lib; do
    codesign --force --sign - "${lib}" 2>/dev/null || log "  (skipped ${lib#${ABS_DIR}/}: not signable)"
done < <(find "${ABS_DIR}" \( -name '*.node' -o -name '*.dylib' \) -type f -print0)

# --- 4. Launch it exactly the way the app does, require /healthcheck ---------
log "Smoke test: starting server on port ${SMOKE_PORT}"
mkdir -p "${WORK}/config" "${WORK}/metadata"
(
    cd "${ABS_DIR}"
    PORT="${SMOKE_PORT}" \
    CONFIG_PATH="${WORK}/config" \
    METADATA_PATH="${WORK}/metadata" \
    SKIP_BINARIES_CHECK=1 \
    FFMPEG_PATH="${ABS_DIR}/ffmpeg" \
    FFPROBE_PATH="${ABS_DIR}/ffprobe" \
    exec "${NODE_BIN}" "${ENTRY}" >"${WORK}/server.log" 2>&1
) &
SERVER_PID=$!

healthy=""
for _ in $(seq 1 45); do
    if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
        break
    fi
    if curl -fsS "http://localhost:${SMOKE_PORT}/healthcheck" >/dev/null 2>&1; then
        healthy=1
        break
    fi
    sleep 2
done

if [ -z "${healthy}" ]; then
    echo "ERROR: ${ABS_TAG} did not pass its launch test. Last server output:" >&2
    tail -n 60 "${WORK}/server.log" >&2 || true
    exit 1
fi
log "Healthcheck passed."
# Let it get past initial DB creation / migrations, then make sure it's still alive.
sleep 10
if ! kill -0 "${SERVER_PID}" 2>/dev/null; then
    echo "ERROR: server exited shortly after passing its healthcheck. Output:" >&2
    tail -n 60 "${WORK}/server.log" >&2 || true
    exit 1
fi
kill "${SERVER_PID}" 2>/dev/null || true
wait "${SERVER_PID}" 2>/dev/null || true
SERVER_PID=""

# --- 5. Package -------------------------------------------------------------
mkdir -p "${OUT_DIR}"
rm -f "${OUT_DIR}/${ASSET}" "${OUT_DIR}/manifest.json"
log "Packaging ${ASSET}"
COPYFILE_DISABLE=1 tar -czf "${OUT_DIR}/${ASSET}" -C "${VENDOR}" node audiobookshelf
sha="$(shasum -a 256 "${OUT_DIR}/${ASSET}" | awk '{print $1}')"

jq -n \
    --arg abs "${ABS_TAG}" \
    --arg node "v${node_version}" \
    --arg asset "${ASSET}" \
    --arg sha "${sha}" \
    --arg arch "${ARCH}" \
    --arg entry "${ENTRY}" \
    --arg built "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{format: 1, abs_version: $abs, node_version: $node, arch: $arch, entry: $entry,
      asset: $asset, sha256: $sha, built_at: $built}' > "${OUT_DIR}/manifest.json"

log "Done: $(du -h "${OUT_DIR}/${ASSET}" | cut -f1) payload, sha256 ${sha}"
cat "${OUT_DIR}/manifest.json"
