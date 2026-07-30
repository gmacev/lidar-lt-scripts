#!/usr/bin/env bash
set -Eeuo pipefail

: "${FAKE_DF_STATE:?FAKE_DF_STATE is required}"

call_count=0
if [[ -f "$FAKE_DF_STATE" ]]; then
    read -r call_count < "$FAKE_DF_STATE"
fi
printf '%d\n' "$((call_count + 1))" > "$FAKE_DF_STATE"

# The first check allows sector 1 to download. Every later check reports only
# 10 GiB available, below process_all.sh's production default of 15 GiB.
if ((call_count == 0)); then
    available_kb=$((20 * 1024 * 1024))
else
    available_kb=$((10 * 1024 * 1024))
fi

printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/fake 104857600 1 %d 1%% /tmp\n' "$available_kb"
