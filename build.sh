#!/bin/bash
#
# Build the self-contained wipe.sh from lib/*.sh modules
#
# The distributed wipe.sh is a single self-contained file so it can be saved
# locally and run with 'sudo bash wipe.sh'.
#
# Usage:
#   ./build.sh
#   ./build.sh --output=/path/to/wipe.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="${SCRIPT_DIR}/wipe.sh"

while [ $# -gt 0 ]; do
    case "$1" in
        --output=*) OUTPUT="${1#--output=}" ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
    shift
done

LIBS=(common.sh sanity.sh unmount.sh sanitize.sh kexec.sh)
MAIN_BODY="${SCRIPT_DIR}/lib/main_body.sh"

# The version is a static reference kept in ./VERSION (no "v" prefix), and is
# bumped by release.sh. print_banner renders it as "v$WIPE_VERSION".
WIPE_VERSION="$(cat "${SCRIPT_DIR}/VERSION")"

# Verify all source files exist
for lib in "${LIBS[@]}"; do
    [ -f "${SCRIPT_DIR}/lib/${lib}" ] || { echo "Missing: lib/${lib}" >&2; exit 1; }
done
[ -f "$MAIN_BODY" ] || { echo "Missing: lib/main_body.sh" >&2; exit 1; }

# Assemble
{
    cat <<HEADER
#!/bin/bash
#
# kexec-wipe - Securely wipe NVMe drives
#
# Usage:
#   curl -sL -o wipe.sh https://raw.githubusercontent.com/chapmanjacobd/kexec-wipe/main/wipe.sh
#   sudo bash wipe.sh /dev/nvme0n1
#
# This file is assembled by build.sh from lib/*.sh modules.
# For development, edit the files in lib/ and run ./build.sh.
#
set -euo pipefail

WIPE_VERSION="${WIPE_VERSION}"
HEADER

    for lib in "${LIBS[@]}"; do
        echo ""
        echo "# --- begin lib/${lib} ---"
        cat "${SCRIPT_DIR}/lib/${lib}"
        echo "# --- end lib/${lib} ---"
    done

    # Embed the initramfs source (the init script and its builder) so wipe.sh
    # can build the initramfs on the target host at runtime, guaranteeing the
    # staged kernel modules match the kernel that will be kexec'd. Emitted as
    # quoted heredocs so nothing in the embedded content is expanded.
    #
    # NOTE: These must be emitted BEFORE main_body.sh. lib/main_body.sh ends
    # with `main "$@"`, and the embedded writer functions are called from the
    # kexec path (build_initramfs_on_host in lib/kexec.sh). Emitting them first
    # guarantees they are defined before main() runs.
    for name in init build.sh; do
        echo ""
        echo "# --- begin embedded: initramfs/${name} ---"
        echo "write_embedded_initramfs_$(echo "$name" | tr . _)() {"
        echo "    cat > \"\$1\" <<'KW_EMBED_$(echo "$name" | tr . _)_EOF'"
        cat "${SCRIPT_DIR}/initramfs/${name}"
        echo "KW_EMBED_$(echo "$name" | tr . _)_EOF"
        echo "}"
        echo "# --- end embedded: initramfs/${name} ---"
    done

    echo ""
    cat "$MAIN_BODY"

} > "${OUTPUT}.tmp"

mv "${OUTPUT}.tmp" "$OUTPUT"
chmod +x "$OUTPUT"

echo "Built: $OUTPUT ($(wc -c < "$OUTPUT") bytes, $(wc -l < "$OUTPUT") lines)"
