#!/usr/bin/env bash
#
# vendor-audiobookshelf.sh
#
# Produces the two things the app bundles for a fully self-contained
# distribution: a pinned Node.js runtime and a pre-built copy of
# Audiobookshelf (deps installed, client already built). Run this once
# before archiving -- or wire it as an Xcode "Run Script" build phase so
# it happens automatically for anyone building this project fresh.
#
# Idempotent: safe to re-run, skips work that's already done. Delete
# Vendor/ to force a clean rebuild of everything.
#
# Output layout (this is what gets added to the Xcode project as folder
# references and copied into Contents/Resources on build):
#   Vendor/node/bin/node
#   Vendor/audiobookshelf/  (index.js, server/, client/dist/, node_modules/,
#                            ffmpeg, ffprobe)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# VENDOR_DIR, NODE_VERSION and ABS_REF can be overridden from the
# environment: scripts/build-abs-payload.sh (used by the abs-payload
# workflow to build updates for already-installed apps) sets all three.
# The defaults below are what gets bundled inside the .app itself.
VENDOR_DIR="${VENDOR_DIR:-${SCRIPT_DIR}/Vendor}"

# --- Pin these deliberately -- don't float to "latest" ---
# Audiobookshelf v2.37.0 moved to Node 24 (see its Dockerfile); the Node
# major here must match whatever the pinned ABS_REF's Dockerfile uses.
NODE_VERSION="${NODE_VERSION:-24.21.0}"
NODE_ARCH="darwin-arm64"   # Mac mini / Apple Silicon only. Use darwin-x64
                            # for Intel if you ever need to support both.
ABS_REPO="https://github.com/advplyr/audiobookshelf.git"
ABS_REF="${ABS_REF:-v2.37.1}"   # pin to a tag, not a moving branch

# Audiobookshelf's own BinaryManager (server/managers/BinaryManager.js)
# downloads ffmpeg/ffprobe from ffbinaries.com, but that service only
# publishes Intel (osx-64) builds for macOS -- there is no osx-arm64
# option there at all. On Apple Silicon that means Audiobookshelf
# always ends up running ffmpeg/ffprobe under Rosetta 2 unless we
# override it ourselves. So we vendor native arm64 static builds from
# eugeneware/ffmpeg-static here and point FFMPEG_PATH/FFPROBE_PATH at
# them (see ServerProcessManager.swift, which also sets
# SKIP_BINARIES_CHECK=1 so Audiobookshelf's own version-gated download
# logic -- which requires a "5.1"-prefixed `-version` string BinaryManager
# won't get from a modern static build -- never runs and overwrites them).
FFMPEG_STATIC_TAG="b6.1.1"
FFMPEG_DARWIN_ARM64_SHA256="a90e3db6a3fd35f6074b013f948b1aa45b31c6375489d39e572bea3f18336584"
FFPROBE_DARWIN_ARM64_SHA256="bb2db6f5d8cef919da12fbf592119a987202a8c060a886f3cab091f9cab90b64"
# -----------------------------------------------------------

NODE_DIST_NAME="node-v${NODE_VERSION}-${NODE_ARCH}"
NODE_TARBALL_URL="https://nodejs.org/dist/v${NODE_VERSION}/${NODE_DIST_NAME}.tar.gz"
NODE_SHASUMS_URL="https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt"

VENDOR_NODE_DIR="${VENDOR_DIR}/node"
VENDOR_ABS_DIR="${VENDOR_DIR}/audiobookshelf"

log() { echo "[vendor] $*"; }

# ---------------------------------------------------------------------------
# 1. Node runtime
# ---------------------------------------------------------------------------
vendor_node() {
    if [ -x "${VENDOR_NODE_DIR}/bin/node" ]; then
        local existing_version
        existing_version="$("${VENDOR_NODE_DIR}/bin/node" --version 2>/dev/null || echo "")"
        if [ "${existing_version}" = "v${NODE_VERSION}" ]; then
            log "Node v${NODE_VERSION} already vendored, skipping download."
            return
        fi
        log "Vendored Node is ${existing_version}, expected v${NODE_VERSION} -- re-vendoring."
        rm -rf "${VENDOR_NODE_DIR}"
    fi

    mkdir -p "${VENDOR_DIR}"
    local tmp_tarball="${VENDOR_DIR}/${NODE_DIST_NAME}.tar.gz"

    log "Downloading ${NODE_TARBALL_URL}"
    curl -fSL -o "${tmp_tarball}" "${NODE_TARBALL_URL}"

    log "Verifying checksum against official SHASUMS256.txt"
    local expected_sha actual_sha
    expected_sha="$(curl -fsSL "${NODE_SHASUMS_URL}" | grep "${NODE_DIST_NAME}.tar.gz" | awk '{print $1}')"
    if [ -z "${expected_sha}" ]; then
        echo "ERROR: could not find checksum entry for ${NODE_DIST_NAME}.tar.gz -- aborting." >&2
        rm -f "${tmp_tarball}"
        exit 1
    fi
    actual_sha="$(shasum -a 256 "${tmp_tarball}" | awk '{print $1}')"
    if [ "${expected_sha}" != "${actual_sha}" ]; then
        echo "ERROR: checksum mismatch for ${NODE_DIST_NAME}.tar.gz" >&2
        echo "  expected: ${expected_sha}" >&2
        echo "  actual:   ${actual_sha}" >&2
        rm -f "${tmp_tarball}"
        exit 1
    fi

    log "Extracting Node runtime"
    mkdir -p "${VENDOR_NODE_DIR}"
    # Only pull bin/ and lib/ (skip docs, headers, etc.) to keep bundle size down.
    tar -xzf "${tmp_tarball}" -C "${VENDOR_NODE_DIR}" --strip-components=1 \
        "${NODE_DIST_NAME}/bin" "${NODE_DIST_NAME}/lib" 2>/dev/null || \
        tar -xzf "${tmp_tarball}" -C "${VENDOR_NODE_DIR}" --strip-components=1
    rm -f "${tmp_tarball}"

    log "Vendored Node: $("${VENDOR_NODE_DIR}/bin/node" --version)"

    # lib/node_modules is npm itself (~19MB) -- needed for the npm ci /
    # npm run generate calls below, but the shipped app only ever
    # executes `node index.js` directly and never invokes npm, so this
    # doesn't belong in the final bundle either. Stripped after
    # vendor_audiobookshelf() finishes using it (see finalize_vendor).
}

# ---------------------------------------------------------------------------
# 2. Pre-built Audiobookshelf
# ---------------------------------------------------------------------------
vendor_audiobookshelf() {
    if [ -f "${VENDOR_ABS_DIR}/macabs-payload.json" ] && [ -d "${VENDOR_ABS_DIR}/node_modules/sequelize" ] \
       && [ -f "${VENDOR_ABS_DIR}/client/dist/200.html" ]; then
        log "Audiobookshelf already vendored and built, skipping."
        return
    fi

    rm -rf "${VENDOR_ABS_DIR}"
    mkdir -p "${VENDOR_DIR}"

    log "Cloning audiobookshelf ${ABS_REF}"
    git clone --depth 1 --branch "${ABS_REF}" "${ABS_REPO}" "${VENDOR_ABS_DIR}"

    local node_bin="${VENDOR_NODE_DIR}/bin/node"
    local npm_bin="${VENDOR_NODE_DIR}/bin/npm"
    if [ ! -x "${node_bin}" ]; then
        echo "ERROR: vendor_node must run before vendor_audiobookshelf." >&2
        exit 1
    fi

    # IMPORTANT: npm itself is a script starting with `#!/usr/bin/env node`,
    # so invoking it by full path does NOT pin which `node` actually runs
    # it -- `env node` still resolves via PATH. Without prepending the
    # vendored bin dir to PATH here, this would silently build against
    # whatever Node happens to already be installed on the machine running
    # this script, which especially matters for sqlite3's compiled native
    # bindings: a build-time/run-time Node version mismatch there causes a
    # NODE_MODULE_VERSION crash the first time the app actually starts.
    export PATH="${VENDOR_NODE_DIR}/bin:${PATH}"
    log "Using $(command -v node) ($(node --version)) for the build"

    # Up to v2.36 the server ran straight from source (index.js). From
    # v2.37 it is TypeScript compiled by `npm run build:server` into
    # dist-server/, and the entry point becomes dist-server/index.js. tsc
    # is a devDependency, so those versions need the full install, then a
    # prune back to production dependencies (native modules such as sqlite3
    # stay built).
    local compiled_server=0
    if grep -q '"build:server"' "${VENDOR_ABS_DIR}/package.json"; then
        compiled_server=1
    fi

    log "Installing root dependencies (this is the ~100MB+ node_modules)"
    if [ "${compiled_server}" = 1 ]; then
        (cd "${VENDOR_ABS_DIR}" && "${npm_bin}" ci)
        log "Compiling server (npm run build:server)"
        (cd "${VENDOR_ABS_DIR}" && "${npm_bin}" run build:server)
        (cd "${VENDOR_ABS_DIR}" && "${npm_bin}" prune --omit=dev)
    else
        (cd "${VENDOR_ABS_DIR}" && "${npm_bin}" ci --omit=dev)
    fi

    log "Building client (Nuxt frontend)"
    (cd "${VENDOR_ABS_DIR}/client" && "${npm_bin}" ci && "${npm_bin}" run generate)

    # client/node_modules is Nuxt's build tooling (webpack, babel, etc.) --
    # ~400MB+, only needed to produce client/dist above. The running
    # server serves client/dist as static files and never touches
    # client/node_modules again, so it doesn't belong in the shipped
    # bundle. This is the single biggest size difference between "builds
    # cleanly" and "matches the ~180MB a user would expect."
    log "Removing client/node_modules (build tooling only, not needed at runtime)"
    rm -rf "${VENDOR_ABS_DIR}/client/node_modules"

    # --omit=dev above skips devDependencies for the root install (mocha,
    # nodemon, etc. -- not needed at runtime, and this is also most of
    # what npm audit flagged earlier as dev-only). The client build still
    # needs its own full install since Nuxt's build tooling is itself a
    # devDependency of the client subproject.

    # Tell the app which file to launch (see ABSRuntime.swift). Also checks
    # the build actually produced it, so a layout change upstream fails
    # here instead of at first launch.
    local entry="index.js"
    if [ "${compiled_server}" = 1 ]; then
        entry="dist-server/index.js"
    fi
    if [ ! -f "${VENDOR_ABS_DIR}/${entry}" ]; then
        echo "ERROR: expected server entry point ${entry} was not produced by the build." >&2
        exit 1
    fi
    "${node_bin}" -e '
        const fs = require("fs");
        const [dir, entry, ref, nodeVersion] = process.argv.slice(1);
        fs.writeFileSync(dir + "/macabs-payload.json", JSON.stringify({
            abs_version: ref, node_version: "v" + nodeVersion, entry: entry
        }, null, 2) + "\n");
    ' "${VENDOR_ABS_DIR}" "${entry}" "${ABS_REF}" "${NODE_VERSION}"

    log "Audiobookshelf vendored: $(cd "${VENDOR_ABS_DIR}" && "${node_bin}" -e "console.log(require('./package.json').version)") (entry: ${entry})"
}

# ---------------------------------------------------------------------------
# 3. Native ffmpeg/ffprobe (arm64 -- see note above on why we can't just
#    let Audiobookshelf's own BinaryManager fetch these)
# ---------------------------------------------------------------------------
vendor_ffmpeg() {
    local base_url="https://github.com/eugeneware/ffmpeg-static/releases/download/${FFMPEG_STATIC_TAG}"

    _fetch_one() {
        local bin_name="$1" expected_sha="$2"
        local dest="${VENDOR_ABS_DIR}/${bin_name}"

        if [ -x "${dest}" ] && [ "$(shasum -a 256 "${dest}" | awk '{print $1}')" = "${expected_sha}" ]; then
            log "${bin_name} already vendored and verified, skipping."
            return
        fi

        mkdir -p "${VENDOR_ABS_DIR}"
        local tmp_gz="${VENDOR_DIR}/${bin_name}-darwin-arm64.gz"
        log "Downloading ${base_url}/${bin_name}-darwin-arm64.gz"
        curl -fSL -o "${tmp_gz}" "${base_url}/${bin_name}-darwin-arm64.gz"

        gunzip -c "${tmp_gz}" > "${dest}"
        rm -f "${tmp_gz}"
        chmod +x "${dest}"

        local actual_sha
        actual_sha="$(shasum -a 256 "${dest}" | awk '{print $1}')"
        if [ "${actual_sha}" != "${expected_sha}" ]; then
            echo "ERROR: checksum mismatch for ${bin_name}-darwin-arm64" >&2
            echo "  expected: ${expected_sha}" >&2
            echo "  actual:   ${actual_sha}" >&2
            rm -f "${dest}"
            exit 1
        fi
        log "Vendored ${bin_name}: $("${dest}" -version | head -1)"
    }

    _fetch_one "ffmpeg" "${FFMPEG_DARWIN_ARM64_SHA256}"
    _fetch_one "ffprobe" "${FFPROBE_DARWIN_ARM64_SHA256}"
}

# ---------------------------------------------------------------------------
# 4. Strip build-only weight from the vendored Node runtime
# ---------------------------------------------------------------------------
finalize_vendor() {
    # npm itself (lib/node_modules) is only needed for the npm ci / npm run
    # generate calls above -- the shipped app calls `node index.js`
    # directly and never invokes npm. Removing it here, not during
    # vendor_node(), since vendor_audiobookshelf() still needs it.
    #
    # Caveat: this means npm is gone for any FUTURE re-vendor of
    # Audiobookshelf alone (e.g. bumping ABS_REF) without also re-running
    # vendor_node from scratch. If you bump ABS_REF, delete Vendor/
    # entirely and re-run this script rather than expecting an in-place
    # partial rebuild to work.
    if [ -d "${VENDOR_NODE_DIR}/lib/node_modules" ]; then
        log "Stripping npm from the vendored runtime (build-time only, ~19MB)"
        rm -rf "${VENDOR_NODE_DIR}/lib/node_modules"
        rm -f "${VENDOR_NODE_DIR}/bin/npm" "${VENDOR_NODE_DIR}/bin/npx" "${VENDOR_NODE_DIR}/bin/corepack"
    fi
}

vendor_node
vendor_audiobookshelf
vendor_ffmpeg
finalize_vendor

log "Done. Vendor/ is ready to add to the Xcode project as folder references."
log "Final size: $(du -sh "${VENDOR_DIR}" | cut -f1)"
