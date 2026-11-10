#!/bin/bash
# Self-test fixture: an SQL error raised through sql_value, the value then printed
# empty. Expected: GUARD uncaught (the server's Msg line reaches the log on stderr).
. "$(dirname "$0")/../lib.sh"
v=$(sql_value "SELECT no_such_col FROM sys.databases")
echo "R|a|$v|"
echo 'R|TOTAL|1'
