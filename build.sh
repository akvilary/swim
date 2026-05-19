#!/bin/bash
set -e
if [ "$(uname -s)" = "Linux" ]; then
    swift build -c release --static-swift-stdlib
else
    swift build -c release
fi
cp .build/release/Swim ~/.local/bin/swim
echo "Installed swim to ~/.local/bin/swim"
