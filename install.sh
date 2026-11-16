#!/bin/sh
# Build + install zpi to ~/.local/bin.
#
# The rm-before-cp and re-sign are NOT optional: overwriting an existing
# file keeps its inode, and macOS taskgated caches the code signature per
# inode — a content change under the same inode makes the kernel kill the
# process with SIGKILL ("Code Signature Invalid") on exec, intermittently.
set -e
cd "$(dirname "$0")"
zig build
rm -f "$HOME/.local/bin/zpi"
cp zig-out/bin/zpi "$HOME/.local/bin/zpi"
codesign -f -s - "$HOME/.local/bin/zpi"
echo "installed: $HOME/.local/bin/zpi"
