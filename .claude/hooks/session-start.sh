#!/bin/bash
# Gives a Claude Code cloud session the compiler this repo needs: zig 0.16.0,
# so `zig build test` (and `zig build kernels`) work before anything is pushed.
#
# ziglang.org is not reachable from cloud sessions, but PyPI publishes the
# same release as the `ziglang` package, which is where it comes from here.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

ZIG_VERSION="0.16.0"
ZIG_HOME="$HOME/.local/zig-$ZIG_VERSION"
ZIG="$ZIG_HOME/ziglang/zig"

# Idempotent: a container that already has it (cached, or resumed) is left alone.
if [ ! -x "$ZIG" ] || [ "$("$ZIG" version 2>/dev/null)" != "$ZIG_VERSION" ]; then
  rm -rf "$ZIG_HOME"
  python3 -m pip install --quiet --disable-pip-version-check --no-cache-dir --root-user-action=ignore \
    --target "$ZIG_HOME" "ziglang==$ZIG_VERSION" >&2
fi

# On PATH for this session's commands.
mkdir -p "$HOME/.local/bin"
ln -sf "$ZIG" "$HOME/.local/bin/zig"
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export PATH=\"$HOME/.local/bin:\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi

echo "zig $("$ZIG" version) ready at $HOME/.local/bin/zig" >&2
