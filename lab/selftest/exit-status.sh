#!/bin/bash
# Self-test fixture: well-formed results, then a non-zero exit. Expected: GUARD exit.
echo 'R|a|ok|'
echo 'R|TOTAL|1'
exit 3
