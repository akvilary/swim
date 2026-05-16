#!/bin/bash
set -e

REPO="akvilary/swim"
LATEST_URL="https://api.github.com/repos/$REPO/releases/latest"

if [ -n "$1" ]; then
    VERSION="$1"
else
    VERSION=$(curl -fsSL "$LATEST_URL" | grep '"tag_name"' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
fi

if [ -z "$VERSION" ]; then
    echo "Error: could not determine latest version" >&2
    exit 1
fi

OS="$(uname -s)"
ARCH="$(uname -m)"

case "$OS" in
    Darwin) FILE="swim-${VERSION}-macos-universal.tar.gz" ;;
    Linux)
        case "$ARCH" in
            x86_64|amd64) FILE="swim-${VERSION}-linux-x86_64.tar.gz" ;;
            *) echo "Error: unsupported architecture $ARCH" >&2; exit 1 ;;
        esac
        ;;
    *) echo "Error: unsupported OS $OS" >&2; exit 1 ;;
esac

URL="https://github.com/$REPO/releases/download/${VERSION}/${FILE}"
DEST="${DESTDIR:-/usr/local/bin}"

echo "Downloading swim ${VERSION} for ${OS} ${ARCH}..."
curl -fSL "$URL" | tar xz -C /tmp

sudo mv /tmp/swim "$DEST/swim"
sudo chmod +x "$DEST/swim"

echo "swim ${VERSION} installed to $DEST/swim"
