#!/usr/bin/env bash
# lazar setup — builds the kernel, locks it, and seeds missing default skills.
# Run from the unpacked tree: bash setup.sh
set -euo pipefail

LAZAR_HOME="${LAZAR_HOME:-$HOME/lazar}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$LAZAR_HOME/workspace/.cargo-target}"
OS_NAME="$(uname -s)"

fail() { echo "error: $*" >&2; exit 1; }
quote() { printf '%q' "$1"; }
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
seal_source() {
    chmod -R a-w "$LAZAR_HOME/src"
}

case "$LAZAR_HOME" in
    ""|"/"|"$HOME") fail "unsafe LAZAR_HOME: $LAZAR_HOME" ;;
    /*) ;;
    *) fail "LAZAR_HOME must be absolute: $LAZAR_HOME" ;;
esac

case "$OS_NAME" in
    Darwin|Linux) ;;
    *) fail "unsupported OS: $OS_NAME (supported: macOS and Linux)" ;;
esac
if [[ "$OS_NAME" == "Linux" && "$(id -u)" == "0" ]]; then
    fail "do not run lazar setup as root; create a dedicated non-root user first"
fi
command -v cargo >/dev/null 2>&1 || fail "cargo not found. Install Rust from https://rustup.rs/"
if [[ "$OS_NAME" == "Darwin" ]]; then
    command -v chflags >/dev/null 2>&1 || fail "chflags not found"
    [[ -x /usr/bin/sandbox-exec ]] || fail "sandbox-exec not found at /usr/bin/sandbox-exec"
else
    command -v bash >/dev/null 2>&1 || { linux_deps_hint; fail "bash not found"; }
    command -v bwrap >/dev/null 2>&1 || { linux_deps_hint; fail "bwrap not found"; }
fi

if [[ ! -d "$SCRIPT_DIR/src" ]]; then
    fail "source tree not found at $SCRIPT_DIR/src"
fi

echo "[lazar] target home: $LAZAR_HOME"
mkdir -p "$LAZAR_HOME"/{skills,memory,workspace,logs,bin,scripts}

# Stage source safely. Reinstalling should not silently delete local kernel edits.
if [[ "$SCRIPT_DIR" != "$LAZAR_HOME" ]]; then
    if [[ ! -d "$LAZAR_HOME/src" ]]; then
        echo "[lazar] first install: copying source into $LAZAR_HOME/src"
        cp -R "$SCRIPT_DIR/src" "$LAZAR_HOME/src"
    elif [[ "${LAZAR_UPDATE_SOURCE:-0}" == "1" ]]; then
        BACKUP="$LAZAR_HOME/src.backup.$(date +%Y%m%d-%H%M%S)"
        echo "[lazar] backing up existing source to $BACKUP"
        chmod -R u+w "$LAZAR_HOME/src" 2>/dev/null || true
        cp -R "$LAZAR_HOME/src" "$BACKUP"
        echo "[lazar] updating source from $SCRIPT_DIR/src (excluding target/)"
        if command -v rsync >/dev/null 2>&1; then
            rsync -a --delete --exclude target/ "$SCRIPT_DIR/src/" "$LAZAR_HOME/src/"
        else
            rm -rf "$LAZAR_HOME/src/.update-tmp"
            cp -R "$SCRIPT_DIR/src" "$LAZAR_HOME/src/.update-tmp"
            rm -rf "$LAZAR_HOME/src/.update-tmp/target"
            cp -R "$LAZAR_HOME/src/.update-tmp/." "$LAZAR_HOME/src/"
            rm -rf "$LAZAR_HOME/src/.update-tmp"
        fi
    else
        echo "[lazar] existing source preserved at $LAZAR_HOME/src"
        echo "[lazar] set LAZAR_UPDATE_SOURCE=1 to update it from this checkout (backup will be created)"
    fi
fi

mkdir -p "$CARGO_TARGET_DIR"
echo "[lazar] cargo build --release (target: $CARGO_TARGET_DIR)"
( cd "$LAZAR_HOME/src" && CARGO_TARGET_DIR="$CARGO_TARGET_DIR" cargo build --release )

BUILT="$CARGO_TARGET_DIR/release/lazar"
[[ -x "$BUILT" ]] || fail "built binary missing at $BUILT"

# Install atomically: prepare a locked temp binary, then swap it in.
echo "[lazar] installing binary atomically"
TMP_BIN="$LAZAR_HOME/bin/.lazar.$$.tmp"
rm -f "$TMP_BIN"
cp "$BUILT" "$TMP_BIN"
chmod 555 "$TMP_BIN"
unlock_binary
mv -f "$TMP_BIN" "$LAZAR_HOME/bin/lazar"
lock_binary
seal_source

# Install helper scripts so printed maintenance commands work from LAZAR_HOME.
if [[ "$SCRIPT_DIR" != "$LAZAR_HOME" ]]; then
    cp -R "$SCRIPT_DIR/scripts/." "$LAZAR_HOME/scripts/"
fi

# Non-destructive default seeding. Full reset is explicit via LAZAR_RESET_ALL=1.
if [[ "${LAZAR_RESET_ALL:-0}" == "1" ]]; then
    echo "[lazar] LAZAR_RESET_ALL=1: factory resetting runtime state"
    "$LAZAR_HOME/bin/lazar" --reset-all --yes
elif [[ ! -f "$LAZAR_HOME/skills/INDEX.md" ]]; then
    echo "[lazar] seeding default skills into empty skills/"
    cp -R "$LAZAR_HOME/src/seed-skills/." "$LAZAR_HOME/skills/"
else
    echo "[lazar] preserving existing skills/memory/workspace/logs (no reset)"
fi

"$LAZAR_HOME/bin/lazar" --help >/dev/null

LINK="/usr/local/bin/lazar"
if [[ -w "/usr/local/bin" ]]; then
    if [[ -e "$LINK" || -L "$LINK" ]]; then
        TARGET="$(readlink "$LINK" 2>/dev/null || true)"
        if [[ "$TARGET" == "$LAZAR_HOME/bin/lazar" ]]; then
            echo "[lazar] symlink already set: $LINK -> $TARGET"
        else
            echo "[lazar] not overwriting existing $LINK (points to: ${TARGET:-regular file})"
            echo "        add to PATH instead: export PATH=\"$LAZAR_HOME/bin:\$PATH\""
        fi
    else
        ln -s "$LAZAR_HOME/bin/lazar" "$LINK"
        echo "[lazar] symlinked $LINK -> $LAZAR_HOME/bin/lazar"
    fi
else
    echo "[lazar] /usr/local/bin not writable; add to PATH yourself:"
    echo "        export PATH=\"$LAZAR_HOME/bin:\$PATH\""
fi

if [[ "$OS_NAME" == "Darwin" ]]; then
    REBUILD_UNLOCK="chflags nouchg $(quote "$LAZAR_HOME/bin/lazar")
             chmod u+w $(quote "$LAZAR_HOME/bin/lazar")"
else
    REBUILD_UNLOCK="chmod u+w $(quote "$LAZAR_HOME/bin/lazar")"
fi

cat <<EOF

[lazar] built and locked for $OS_NAME.

  api key:   export ANTHROPIC_API_KEY=***
  use:       lazar -p "your prompt here"
  reset:     lazar --reset-all
  rebuild:   $REBUILD_UNLOCK
             chmod -R u+w $(quote "$LAZAR_HOME/src")
             bash $(quote "$LAZAR_HOME/scripts/kernel-build.sh")

EOF
