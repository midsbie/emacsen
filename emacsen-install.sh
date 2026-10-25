#!/usr/bin/env bash
# The in-container half of `emacsen install`, which passes this file to bash -c inside the image.
# It runs as root with the install target bind-mounted at /usr/local, the image's configured
# build tree as the working directory, EMACSEN_IMAGE_ID, EMACSEN_IMAGE_TAG and
# EMACSEN_EMACS_VERSION naming the image and its Emacs, and EMACSEN_SOURCE_DIRECTORY naming that
# Emacs's dumped source-directory. It is not for running on the host.

set -euo pipefail

fatal() { printf 'emacsen: %s\n' "$*" >&2; exit 1; }

command -v install-info >/dev/null \
    || fatal "image has no install-info; rebuild it with: emacsen build ${EMACSEN_IMAGE_TAG#emacsen:}"
command -v flock >/dev/null || fatal "image has no flock: $EMACSEN_IMAGE_TAG"
[[ $EMACSEN_SOURCE_DIRECTORY == /usr/local/share/emacs/*/ ]] \
    || fatal "source-directory is not under /usr/local/share/emacs: $EMACSEN_SOURCE_DIRECTORY"

state=/usr/local/lib/emacsen
mkdir -p -- "$state/installed"

# Every version shares bin/emacs, the manuals and the info directory, so installs into one prefix
# hold one lock, which lives in the prefix to be shared by every checkout. A second install is
# refused, not queued: queueing would let timing choose which install owns bin/emacs.
exec {lock}>> "$state/install.lock"
flock --nonblock "$lock" \
    || fatal "another install into this prefix holds lib/emacsen/install.lock"

make install

# make install leaves the C sources in the tree; the installed Emacs looks for them in the src/
# of its source-directory. Replace the version's copy whole, as make install replaces its lisp/.
sources=${EMACSEN_SOURCE_DIRECTORY}src
staged=$(mktemp -d "${EMACSEN_SOURCE_DIRECTORY}.src-XXXXXXXX") \
    || fatal "cannot stage C sources in $EMACSEN_SOURCE_DIRECTORY"
trap 'rm -rf -- "$staged"' EXIT
install -m 644 -- src/*.[ch] "$staged" || fatal "cannot copy C sources into $staged"
chmod 755 -- "$staged"
rm -rf -- "$sources"
mv -- "$staged" "$sources"

# One record per version: make install leaves other versions' trees in place.
record=$state/installed/$EMACSEN_EMACS_VERSION
scratch=$(mktemp "$state/installed/.record-XXXXXXXX")
trap 'rm -f -- "$scratch"' EXIT
{
    printf 'image-id: %s\nimage-tag: %s\n\n' "$EMACSEN_IMAGE_ID" "$EMACSEN_IMAGE_TAG"
    cat /usr/share/emacsen/build-info
} > "$scratch"
chmod 644 -- "$scratch"
mv -- "$scratch" "$record"
