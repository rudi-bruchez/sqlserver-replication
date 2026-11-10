#!/bin/bash
# Self-test fixture: leaves a snapshot folder whose publication part is a lower-case
# m_ name. Expected: GUARD residue. selftest.sh removes it right after.
set -euo pipefail
podman exec repllab mkdir /var/opt/mssql/data/ReplData/unc/REPLLAB_SALES_m_ghost
echo 'R|a|ok|'
echo 'R|TOTAL|1'
