#!/usr/bin/env bash
set -uo pipefail

for argument in "$@"; do
    if [[ "$argument" == */02_02/* ]]; then
        printf 'Intentional acceptance-test failure for sector 02_02\n' >&2
        exit 42
    fi
done

cd /opt/potreeconverter-2.1.1/PotreeConverter_linux_x64
exec ./PotreeConverter "$@"
