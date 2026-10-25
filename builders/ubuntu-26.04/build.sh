#!/usr/bin/env bash
set -euo pipefail

: "${BASE_IMAGE:?}" "${TARGETPLATFORM:?}" "${SOURCE_SHA256:?}" "${CC:?}" "${EMACS_PREFIX:?}" "${VARIANT:?}"

archive=/source/archive
printf '%s  %s\n' "$SOURCE_SHA256" "$archive" | sha256sum --check --strict
mkdir -p /build/emacs
tar -xf "$archive" --strip-components=1 -C /build/emacs
cd /build/emacs
if [[ ! -f configure ]]; then ./autogen.sh; fi

# Loaded before dumping, as Emacs's INSTALL describes. The dump would otherwise record
# source-directory as this tree, which an installed Emacs cannot reach. Name the version's data
# directory instead: its lisp/ and etc/ mirror the tree's, and its src/ takes the C sources.  The
# prefix is written in because Emacs dumps without the process environment.
if [[ -e lisp/site-init.el || -L lisp/site-init.el ]]; then
    printf 'Source already has lisp/site-init.el\n' >&2
    exit 1
fi
# Partly redundant since configure rejects a relative --prefix; quotes and backslashes are banned
# because the prefix goes into an Elisp string.
if [[ $EMACS_PREFIX != /* || $EMACS_PREFIX == *[\"\\]* ]]; then
    printf 'Prefix must be absolute, without quotes or backslashes: %s\n' "$EMACS_PREFIX" >&2
    exit 1
fi
{
    printf ';; -*- lexical-binding: t -*-\n'
    printf '(setq source-directory (expand-file-name (concat "share/emacs/" emacs-version "/") "%s"))\n' \
        "$EMACS_PREFIX"
} > lisp/site-init.el

configure_options=(
    "--prefix=$EMACS_PREFIX"
    --enable-link-time-optimization
    --with-native-compilation
    --with-gnutls
    --with-tree-sitter
    --with-xml2
    --without-pop
    --without-wide-int
)
case $VARIANT in
    server)
        configure_options+=(
            --without-x
            --without-dbus
            --without-gconf
            --without-gsettings
            --with-sound=no
        )
        ;;
    x)
        configure_options+=(
            --with-dbus
            --with-jpeg
            --with-png
            --with-rsvg
            --with-tiff
            --with-xft
            --with-xpm
        )
        ;;
    *) printf 'Unknown variant: %s\n' "$VARIANT" >&2; exit 1 ;;
esac

./configure "${configure_options[@]}"
make -j"$(nproc)" bootstrap
make install

# Layer export can change subsecond ordering between generated inputs and outputs.
# Equal timestamps leave the retained tree up to date for a later make install.
timestamp=$(date +%s)
find /build/emacs -exec touch -h -d "@$timestamp" {} +

actual_version=$("$EMACS_PREFIX/bin/emacs" -Q --batch --eval '(princ emacs-version)')
if [[ -n ${EMACS_VERSION:-} && $actual_version != "$EMACS_VERSION" ]]; then
    printf 'Expected Emacs %s, installed %s\n' "$EMACS_VERSION" "$actual_version" >&2
    exit 1
fi

source_directory=$("$EMACS_PREFIX/bin/emacs" -Q --batch --eval '(princ source-directory)')
if [[ $source_directory != "$EMACS_PREFIX/share/emacs/$actual_version/" ]]; then
    printf 'Expected source-directory %s, dumped %s\n' \
        "$EMACS_PREFIX/share/emacs/$actual_version/" "$source_directory" >&2
    exit 1
fi
# The image's own Emacs reads its C sources from the tree.
ln -s -- /build/emacs/src "${source_directory}src"

# shellcheck disable=SC1091 # Supplied by the image's base distribution.
. /etc/os-release
{
    printf 'emacs-version: %s\nprefix: %s\nos-release: %s %s\n' \
        "$actual_version" "$EMACS_PREFIX" "$ID" "$VERSION_ID"
    printf 'build-tree: /build/emacs\nsource-directory: %s\nvariant: %s\n' \
        "$source_directory" "$VARIANT"
    printf 'base-image: %s\nplatform: %s\narchitecture: %s\npatches: none\n' \
        "$BASE_IMAGE" "$TARGETPLATFORM" "$(dpkg --print-architecture)"
    printf '\n[configure]\n'
    ./config.status --config
    printf '\n[compiler]\n'
    "$CC" --version
    printf '\n[packages]\n'
    dpkg-query -W -f '${binary:Package}\t${Version}\t${Architecture}\n' | LC_ALL=C sort
} > /usr/share/emacsen/build-info
