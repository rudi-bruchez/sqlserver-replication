#!/bin/bash
# Self-test fixture: leaves an upper-case M_ file below the top of the data folder.
# Expected: GUARD residue. selftest.sh removes it right after.
set -euo pipefail
podman exec repllab touch /var/opt/mssql/data/ReplData/M_LEFT.bak
echo 'R|a|ok|'
echo 'R|TOTAL|1'
