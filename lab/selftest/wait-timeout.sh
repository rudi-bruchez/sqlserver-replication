#!/bin/bash
# Self-test fixture: a wait that never succeeds. Expected: GUARD results,
# because the cases are printed only when wait_until returns 0.
set -uo pipefail
. "$(dirname "$0")/../lib.sh"
if wait_until 10 "SELECT 0"; then
    echo 'R|a|ok|'
    echo 'R|TOTAL|1'
fi
