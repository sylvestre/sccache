#!/usr/bin/env bash
#
# Build sccache from /sccache, then run a narrow Firefox build against a
# pinned mozilla-firefox/firefox tree with sccache wired in as
# --with-ccache and RUSTC_WRAPPER. Fail if compiles did not flow through
# sccache. See .taskcluster.yml and the design plan for context.

set -euxo pipefail

: "${MOZ_FIREFOX_REV:=main}"
: "${RUST_VERSION:=stable}"

SCCACHE_SRC=/sccache
FIREFOX_SRC=/firefox
SCCACHE_BIN="${SCCACHE_SRC}/target/release/sccache"
ARTIFACTS=/builds/worker/artifacts

mkdir -p "${ARTIFACTS}"

apt-get update
apt-get install -y --no-install-recommends \
    build-essential \
    clang \
    curl \
    git \
    libssl-dev \
    lld \
    mercurial \
    pkg-config \
    python3 \
    python3-pip \
    xz-utils

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain "${RUST_VERSION}" --profile minimal
# shellcheck source=/dev/null
. "${HOME}/.cargo/env"

cd "${SCCACHE_SRC}"
cargo build --release
"${SCCACHE_BIN}" --version

# Start the server with a clean slate so --show-stats reflects only
# what the Firefox build did.
"${SCCACHE_BIN}" --stop-server >/dev/null 2>&1 || true
"${SCCACHE_BIN}" --start-server
"${SCCACHE_BIN}" --zero-stats

git clone --depth 1 --branch "${MOZ_FIREFOX_REV}" \
    https://github.com/mozilla-firefox/firefox "${FIREFOX_SRC}"
cd "${FIREFOX_SRC}"

./mach --no-interactive bootstrap \
    --application-choice=browser \
    --no-system-changes

cat > "${FIREFOX_SRC}/mozconfig" <<EOF
ac_add_options --enable-application=browser
ac_add_options --disable-debug
ac_add_options --enable-release
ac_add_options --with-ccache=${SCCACHE_BIN}
mk_add_options 'export RUSTC_WRAPPER=${SCCACHE_BIN}'
mk_add_options 'export SCCACHE_LOG=info'
EOF
export MOZCONFIG="${FIREFOX_SRC}/mozconfig"

# Always copy config.log out, even on failure.
trap 'cp -f "${FIREFOX_SRC}"/obj-*/config.log "${ARTIFACTS}/firefox-config.log" 2>/dev/null || true' EXIT

./mach configure 2>&1 | tee "${ARTIFACTS}/firefox-build.log"

# pre-export+export exercises the build-system glue (and runs cargo,
# which routes through RUSTC_WRAPPER). config/external/zlib is a small
# C target that drives a real --with-ccache compile. Together: a few
# minutes of wall time, both wrapper paths covered.
./mach build pre-export export 2>&1 | tee -a "${ARTIFACTS}/firefox-build.log"
./mach build config/external/zlib 2>&1 | tee -a "${ARTIFACTS}/firefox-build.log"

"${SCCACHE_BIN}" --show-stats | tee "${ARTIFACTS}/sccache-stats.txt"

# Assert sccache actually saw work. The worker has no prior cache, so
# we don't check hit rate — only that compiles flowed through and were
# accepted.
compile_requests=$(awk '/^Compile requests[^ ]* +/ {print $NF; exit}' \
    "${ARTIFACTS}/sccache-stats.txt")
non_cacheable=$(awk '/^Non-cacheable compilations/ {print $NF; exit}' \
    "${ARTIFACTS}/sccache-stats.txt")

if [[ -z "${compile_requests}" || "${compile_requests}" -le 0 ]]; then
    echo "FAIL: sccache saw 0 compile requests — sccache was not invoked." >&2
    exit 1
fi
if [[ -n "${non_cacheable}" && "${non_cacheable}" -gt 0 ]]; then
    echo "FAIL: ${non_cacheable} non-cacheable compilations — sccache rejected work." >&2
    exit 1
fi

"${SCCACHE_BIN}" --stop-server || true
