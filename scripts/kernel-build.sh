#!/usr/bin/env bash
# Rebuild the kernel and relock. Run after editing src/.
# If the build fails, the source stays writable so you can fix and retry.
set -euo pipefail

LAZAR_HOME="${LAZAR_HOME:-$HOME/lazar}"
CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$LAZAR_HOME/workspace/.cargo-target}"
OS_NAME="$(uname -s)"

fail() { echo "error: $*" >&2; exit 1; }
linux_deps_hint() {
    echo "On Ubuntu/Debian, install dependencies with:" >&2
    echo "  sudo apt-get update && sudo apt-get install -y bubblewrap build-essential pkg-config libssl-dev curl ca-certificates git" >&2
}
unlock_binary() {
    if [[ "$OS_NAME" == "Darwin" ]]; then
        chflags nouchg "$LAZAR_HOME/bin/lazar" 2>/dev/null || true
    fi
    chmod u+w "$LAZAR_HOME/bin/lazar" 2>/dev/null || true
}
lock_binary() {
    chmod 555 "$LAZAR_HOME/bin/lazar"
    if [[ "$OS_NAME" == "Darwin" ]]; then
        chflags uchg "$LAZAR_HOME/bin/lazar"
    fi
}

case "$LAZAR_HOME" in
    ""|"/"|"$HOME") fail "unsafe LAZAR_HOME: $LAZAR_HOME" ;;
    /*) ;;
    *) fail "LAZAR_HOME must be absolute: $LAZAR_HOME" ;;
esac

command -v cargo >/dev/null 2>&1 || fail "cargo not found. Install Rust: https://rustup.rs/"
case "$OS_NAME" in
    Darwin)
        command -v chflags >/dev/null 2>&1 || fail "chflags not found"
        [[ -x /usr/bin/sandbox-exec ]] || fail "sandbox-exec not found at /usr/bin/sandbox-exec"
        ;;
    Linux)
        if [[ "$(id -u)" == "0" ]]; then
            fail "do not rebuild lazar as root; use the dedicated non-root lazar user"
        fi
        command -v bash >/dev/null 2>&1 || { linux_deps_hint; fail "bash not found"; }
        command -v bwrap >/dev/null 2>&1 || { linux_deps_hint; fail "bwrap not found"; }
        ;;
    *) fail "unsupported OS: $OS_NAME (supported: macOS and Linux)" ;;
esac
[[ -d "$LAZAR_HOME/src" ]] || fail "source tree missing at $LAZAR_HOME/src"

mkdir -p "$CARGO_TARGET_DIR" "$LAZAR_HOME/bin"

echo "[kernel-build] cargo build --release (target: $CARGO_TARGET_DIR)"
( cd "$LAZAR_HOME/src" && CARGO_TARGET_DIR="$CARGO_TARGET_DIR" cargo build --release )

BUILT="$CARGO_TARGET_DIR/release/lazar"
[[ -x "$BUILT" ]] || fail "built binary missing at $BUILT"

echo "[kernel-build] swapping in new binary atomically"
TMP_BIN="$LAZAR_HOME/bin/.lazar.$$.tmp"
rm -f "$TMP_BIN"
cp "$BUILT" "$TMP_BIN"
chmod 555 "$TMP_BIN"
unlock_binary
mv -f "$TMP_BIN" "$LAZAR_HOME/bin/lazar"

lock_binary
chmod -R a-w "$LAZAR_HOME/src"

echo "[kernel-build] done. Kernel rebuilt and locked for $OS_NAME."
echo "[kernel-build] try:  lazar -p 'hello'"
