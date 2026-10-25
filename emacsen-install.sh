#!/usr/bin/env bash
# The in-container half of `emacsen install` and `emacsen uninstall`, which pass this file to bash
# -c inside the image with the action as its argument. It runs as root with the target bind-mounted
# at the image's prefix, the image's configured build tree as the working directory,
# EMACSEN_IMAGE_ID, EMACSEN_IMAGE_TAG and EMACSEN_EMACS_VERSION naming the image and its Emacs, and
# EMACSEN_STATE_DIRECTORY naming emacsen's state directory in the target.
#
# Install also takes EMACSEN_SOURCE_DIRECTORY, that Emacs's dumped source-directory. It is not for
# running on the host.

set -euo pipefail

fatal() { printf 'emacsen: %s\n' "$*" >&2; exit 1; }

install_emacs() (
    local sources staged scratch

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
    scratch=$(mktemp "$EMACSEN_STATE_DIRECTORY/installed/.record-XXXXXXXX")
    trap 'rm -f -- "$scratch"' EXIT
    {
        printf 'image-id: %s\nimage-tag: %s\n\n' "$EMACSEN_IMAGE_ID" "$EMACSEN_IMAGE_TAG"
        cat /usr/share/emacsen/build-info
    } > "$scratch"
    chmod 644 -- "$scratch"
    mv -- "$scratch" "$record"
)

uninstall_emacs() (
    local line entry

    # The host read the record before this lock was held; a reinstall since would have rewritten
    # it. Install writes image-id first.
    [[ -f $record ]] || fatal "no installation record for Emacs $EMACSEN_EMACS_VERSION: $record"
    IFS= read -r line < "$record"
    [[ $line == "image-id: $EMACSEN_IMAGE_ID" ]] \
        || fatal "installation record changed since it was read; retry: $record"

    # make uninstall removes the shared binaries and manuals whichever version installed them.
    shopt -s nullglob
    for entry in "$EMACSEN_STATE_DIRECTORY/installed/"*; do
        [[ $entry == "$record" ]] \
            || fatal "uninstall requires exactly one recorded version; also found: $entry"
    done

    make uninstall
    rm -- "$record"
)

action=${1-}
[[ $action == install || $action == uninstall ]] \
    || fatal "expected the action install or uninstall, got: $action"

command -v install-info >/dev/null \
    || fatal "image has no install-info; rebuild it with: emacsen build ${EMACSEN_IMAGE_TAG#emacsen:}"
command -v flock >/dev/null \
    || fatal "image has no flock: $EMACSEN_IMAGE_TAG"

record=$EMACSEN_STATE_DIRECTORY/installed/$EMACSEN_EMACS_VERSION
mkdir -p -- "$EMACSEN_STATE_DIRECTORY/installed"

# Every version shares bin/emacs, the manuals and the info directory, so install and uninstall into
# one prefix hold one lock, which lives in the prefix to be shared by every checkout and outlives
# the last record. A second operation is refused, not queued: queueing would let timing choose
# which install owns bin/emacs.
exec {lock}>> "$EMACSEN_STATE_DIRECTORY/install.lock"
flock --nonblock "$lock" \
    || fatal "another install or uninstall holds $EMACSEN_STATE_DIRECTORY/install.lock"

case $action in
    install) install_emacs ;;
    uninstall) uninstall_emacs ;;
esac
