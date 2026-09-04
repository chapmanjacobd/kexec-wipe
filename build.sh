#!/bin/bash
#
# Build the self-contained wipe.sh from lib/*.sh modules
#
# The distributed wipe.sh has all library code inlined so it works
# when piped via curl | bash.
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

# Verify all source files exist
for lib in "${LIBS[@]}"; do
    [ -f "${SCRIPT_DIR}/lib/${lib}" ] || { echo "Missing: lib/${lib}" >&2; exit 1; }
done
[ -f "$MAIN_BODY" ] || { echo "Missing: lib/main_body.sh" >&2; exit 1; }

# Assemble
{
    cat <<'HEADER'
#!/bin/bash
#
# kexec-wipe - Securely wipe NVMe drives
#
# Usage:
#   curl -sL https://raw.githubusercontent.com/chapmanjacobd/kexec-wipe/main/wipe.sh | sudo bash -s /dev/nvme0n1
#
# This file is assembled by build.sh from lib/*.sh modules.
# For development, edit the files in lib/ and run ./build.sh.
#
set -euo pipefail

WIPE_VERSION="0.1.0"
HEADER

    for lib in "${LIBS[@]}"; do
        echo ""
        echo "# --- begin lib/${lib} ---"
        cat "${SCRIPT_DIR}/lib/${lib}"
        echo "# --- end lib/${lib} ---"
    done

    echo ""
    cat "$MAIN_BODY"

} > "${OUTPUT}.tmp"

mv "${OUTPUT}.tmp" "$OUTPUT"
chmod +x "$OUTPUT"

echo "Built: $OUTPUT ($(wc -c < "$OUTPUT") bytes, $(wc -l < "$OUTPUT") lines)"
