#!/bin/bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../lib/zram-settings.sh
source "$ROOT/lib/zram-settings.sh"
ZRAM_TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$ZRAM_TEST_DIR"' EXIT
zram_dietpi_config_owned "$ZRAM_TEST_DIR/missing.conf"
printf '%s\nzram\n' "$ZRAM_DIETPI_MARKER" > "$ZRAM_TEST_DIR/owned.conf"
zram_dietpi_config_owned "$ZRAM_TEST_DIR/owned.conf"
printf 'zram\n' > "$ZRAM_TEST_DIR/foreign.conf"
if zram_dietpi_config_owned "$ZRAM_TEST_DIR/foreign.conf"; then
    printf 'Foreign configuration must not be overwritten\n' >&2; exit 1
fi
mkdir "$ZRAM_TEST_DIR/directory.conf"
if zram_dietpi_config_owned "$ZRAM_TEST_DIR/directory.conf"; then
    printf 'Directories must not be overwritten\n' >&2; exit 1
fi
# Git Bash can emulate ln with a copy; check links only where actually supported.
if ln -s owned.conf "$ZRAM_TEST_DIR/link.conf" 2>/dev/null && [[ -L $ZRAM_TEST_DIR/link.conf ]]; then
    if zram_dietpi_config_owned "$ZRAM_TEST_DIR/link.conf"; then
        printf 'Owned marker must not authorize symlink writes\n' >&2; exit 1
    fi
fi
info() { :; }
warn() { :; }
systemctl() { printf 'Unexpected systemctl invocation\n' >&2; exit 99; }
stage_file() { printf 'Unexpected staging\n' >&2; exit 98; }
healthy_zram() { return 0; }
prepare_zram_settings
[[ $ZRAM_BACKEND == existing ]]
DRY_RUN=0
activate_zram
healthy_zram() { return 1; }
if activate_zram; then printf 'Lost zram must fail verification\n' >&2; exit 1; fi
ZRAM_BACKEND=armbian-pending
if activate_zram; then printf 'Pending reboot must not permit disk swap removal\n' >&2; exit 1; fi
ZRAM_BACKEND=unsupported
if activate_zram; then printf 'Unknown OS must not permit disk swap removal\n' >&2; exit 1; fi
DRY_RUN=1
ZRAM_BACKEND=dietpi
activate_zram
printf 'zram settings control-flow tests passed\n'
