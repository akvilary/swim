#!/bin/bash
set -e

REPO="akvilary/swim"
LATEST_URL="https://api.github.com/repos/$REPO/releases/latest"

# Symbols Nerd Font, Mono variant — the icon glyphs behind the file
# explorer's Nerd Font tier. Pinned release + sha256: GitHub release
# assets are immutable per tag, so the pin makes every install
# reproducible and tamper-evident. The font is user-scoped and no
# terminal configuration is touched — terminals that lack the glyphs
# in their main font pick this one up through their own fallback
# (fontconfig on Linux, CoreText on macOS; kitty prefers it
# automatically). A missing font never blocks the editor (fail-open:
# icons fall back through SWIM_ICONS).
FONT_VERSION="v3.5.1"
FONT_SHA256="01172f37db8543edb102e5cb5c64101c9f4686630804d49b419aa07b23a69996"
FONT_TARBALL="NerdFontsSymbolsOnly.tar.xz"
FONT_URL="https://github.com/ryanoasis/nerd-fonts/releases/download/${FONT_VERSION}/${FONT_TARBALL}"
FONT_FILE="SymbolsNerdFontMono-Regular.ttf"

NO_FONT=0
VERSION=""
for arg in "$@"; do
    case "$arg" in
        --no-font) NO_FONT=1 ;;
        *) VERSION="$arg" ;;
    esac
done

if [ -z "$VERSION" ]; then
    VERSION=$(curl -fsSL "$LATEST_URL" | grep '"tag_name"' | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
fi

if [ -z "$VERSION" ]; then
    echo "Error: could not determine latest version" >&2
    exit 1
fi

# Fail-open by construction: every failure path warns and returns 0 —
# the font is an enhancement, and `set -e` above must not turn a
# network hiccup into a failed editor install.
install_font() {
    local dest
    case "$(uname -s)" in
        Darwin) dest="$HOME/Library/Fonts" ;;
        *) dest="$HOME/.local/share/fonts" ;;
    esac
    local marker="$dest/.swim-symbols-nerd-font-$FONT_VERSION"
    if [ -e "$marker" ]; then
        echo "Symbols Nerd Font Mono $FONT_VERSION already present"
        return 0
    fi
    echo "Installing Symbols Nerd Font Mono $FONT_VERSION (explorer icons; --no-font skips this)..."
    local tmp
    tmp=$(mktemp -d)
    if ! curl -fSL "$FONT_URL" -o "$tmp/$FONT_TARBALL"; then
        echo "Warning: font download failed (offline?) — swim works, icons fall back" >&2
        return 0
    fi
    local got
    if command -v sha256sum >/dev/null 2>&1; then
        got=$(sha256sum "$tmp/$FONT_TARBALL" | awk '{print $1}')
    else
        got=$(shasum -a 256 "$tmp/$FONT_TARBALL" | awk '{print $1}')
    fi
    if [ "$got" != "$FONT_SHA256" ]; then
        echo "Warning: font checksum mismatch — skipping the font, swim works without it" >&2
        return 0
    fi
    if ! tar xJf "$tmp/$FONT_TARBALL" -C "$tmp"; then
        echo "Warning: font archive did not unpack — skipping the font" >&2
        return 0
    fi
    mkdir -p "$dest"
    if ! cp "$tmp/$FONT_FILE" "$dest/"; then
        echo "Warning: could not copy the font into $dest — skipping" >&2
        return 0
    fi
    touch "$marker"
    if command -v fc-cache >/dev/null 2>&1; then
        fc-cache -f "$dest" >/dev/null 2>&1 || true
    fi
    rm -rf "$tmp"
    echo "Symbols Nerd Font Mono installed to $dest"
}

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

if [ "$NO_FONT" -ne 1 ]; then
    install_font
fi
