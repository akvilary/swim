#!/bin/bash
set -e
if [ "$(uname -s)" = "Linux" ]; then
    swift build -c release --static-swift-stdlib
else
    swift build -c release
fi
# Atomic rename: a plain cp fails with ETXTBSY while swim is running;
# mv swaps the inode, the running process keeps the old binary.
cp .build/release/Swim ~/.local/bin/swim.new && mv ~/.local/bin/swim.new ~/.local/bin/swim
echo "Installed swim to ~/.local/bin/swim"
