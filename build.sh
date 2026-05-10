#!/bin/bash
set -e
swift build -c release
cp .build/release/Swim ~/.local/bin/swim
echo "Installed swim to ~/.local/bin/swim"
