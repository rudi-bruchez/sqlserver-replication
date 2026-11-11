# Helpers shared by lab/campaign/11-defaults.sh and lab/distributor-defaults.sh, which
# measure the value each replication procedure stores for a parameter that is not passed.
# Source it after lab/lib.sh; DEF_SCRIPT names the caller in error messages, and
# DEF_CONTAINER (default repllab) is the container whose definitions are read.
#
# Optional parameters. sys.all_parameters lists every parameter of a procedure, but its
# has_default_value is 0 for every T-SQL module, system procedures included (checked on
# the lab for sp_addpublication). The script therefore reads the procedure's own
# definition (OBJECT_DEFINITION of sys.<proc>, which keeps the declared defaults; the
# 2019 copies in stored-procedures/ were scripted without them), takes its parameter
# header, and calls a parameter optional when its declaration has "= default". The names
# found in the header must be those of sys.all_parameters, in the same order, or the
# script stops: the count it prints is the count of sys.all_parameters rows with a
# declared default.
#
# Mapping. Each measured procedure has a map: one line per optional parameter,
#   @parameter|column it sets|T-SQL expression of the stored value
# evaluated after the call, in a batch that starts with the procedure's preamble (temporary
# tables #x holding the catalog rows of the object the call created). An expression
# returns N'no-column' when no catalog column holds the parameter; the description says
# why. A parameter of the procedure without a map line, or a map line naming a parameter
# that is not optional, stops the script: the map is checked against the live procedure,
# so that a 2019 or 2025 run cannot silently skip a parameter.
# {P}, {A}, {D} in a preamble or a map are replaced by the publication, article and
# database of the context.

: "${DEF_SCRIPT:?DEF_SCRIPT must name the calling script}"
DEF_CONTAINER=${DEF_CONTAINER:-repllab}

def_fail() { echo "$DEF_SCRIPT: $*" >&2; exit 1; }

# sqlraw QUERY: the full value of a max column (no -W, -y 0 does not cut at 256).
sqlraw() {
    podman exec -i -e SQLCMDPASSWORD="$MSSQL_SA_PASSWORD" "$DEF_CONTAINER" \
        /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -b -y 0 -Q "SET NOCOUNT ON; $1" </dev/null
}

# optional_params PROC: fills OPT_NAMES and OPT_DEFAULTS with the optional parameters of
# sys.PROC, in parameter order.
OPT_NAMES=(); OPT_DEFAULTS=()
optional_params() {
    local proc=$1 def parsed catalog header_names
    def=$(sqlraw "SELECT OBJECT_DEFINITION(OBJECT_ID(N'sys.$proc'))") || def_fail "cannot read the definition of sys.$proc"
    # Prints name<TAB>0|1<TAB>declared default, one parameter per line.
    parsed=$(printf '%s' "$def" | perl -e '
        local $/; $_ = <STDIN>;
        s{/\*.*?\*/}{ }gs; s{--[^\n]*}{ }g;
        /create\s+proc(?:edure)?\s+(?:\[?sys\]?\.)?\[?\w+\]?/ig or die "no create procedure\n";
        my $rest = substr($_, pos($_));
        my $h;
        if ($rest =~ /^\s*\(/) {
            my $start = index($rest, "("); my ($d, $i) = (0, 0);
            for ($i = $start; $i < length($rest); $i++) {
                my $c = substr($rest, $i, 1);
                if ($c eq "\x27") { $i++ while $i + 1 < length($rest) && substr($rest, $i + 1, 1) ne "\x27"; $i++; next; }
                $d++ if $c eq "("; $d-- if $c eq ")"; last if $d == 0;
            }
            $h = substr($rest, $start + 1, $i - $start - 1);
        } else {
            my ($q, $i, $end) = (0, 0, -1);
            for ($i = 0; $i < length($rest); $i++) {
                my $c = substr($rest, $i, 1);
                if ($c eq "\x27") { $q = !$q; next; }
                next if $q;
                if (lc(substr($rest, $i, 2)) eq "as" && ($i == 0 || substr($rest, $i - 1, 1) !~ /\w/) && substr($rest, $i + 2, 1) !~ /\w/) { $end = $i; last; }
            }
            $end >= 0 or die "no AS after the header\n"; $h = substr($rest, 0, $end);
        }
        my @parts; my ($cur, $d, $q) = ("", 0, 0);
        for my $c (split //, $h) {
            if ($c eq "\x27") { $q = !$q; }
            elsif (!$q && $c eq "(") { $d++; } elsif (!$q && $c eq ")") { $d--; }
            if (!$q && $d == 0 && $c eq ",") { push @parts, $cur; $cur = ""; next; }
            $cur .= $c;
        }
        push @parts, $cur;
        for my $p (@parts) {
            $p =~ s/\s+/ /g; $p =~ s/^ //; $p =~ s/ $//;
            next if $p eq "";
            $p =~ /^(@\w+)\s+(.*)$/ or die "unparsed parameter: $p\n";
            my ($n, $t) = ($1, $2);
            if ($t =~ /=\s*(.*?)\s*(?:\b(?:output|out)\b)?\s*$/i) { print "$n\t1\t$1\n"; } else { print "$n\t0\t\n"; }
        }') || def_fail "cannot parse the parameter header of sys.$proc"
    catalog=$(sql_value "SELECT STRING_AGG(CONVERT(nvarchar(4000), name), N' ') WITHIN GROUP (ORDER BY parameter_id) FROM sys.all_parameters WHERE object_id = OBJECT_ID(N'sys.$proc')") \
        || def_fail "cannot read sys.all_parameters for sys.$proc"
    header_names=$(printf '%s\n' "$parsed" | cut -f1 | tr '\n' ' ' | sed 's/ $//')
    [ "$header_names" = "$catalog" ] || def_fail "sys.$proc: header [$header_names] differs from sys.all_parameters [$catalog]"
    OPT_NAMES=(); OPT_DEFAULTS=()
    local n o d
    while IFS=$'\t' read -r n o d; do
        [ "$o" = 1 ] || continue
        OPT_NAMES+=("$n"); OPT_DEFAULTS+=("$d")
    done <<<"$parsed"
}

# SQL fragments used by the maps.
# srv EXPR: the server name of a replication server id.
srv() { echo "(SELECT srvname FROM distribution.dbo.MSreplservers WHERE srvid = $1)"; }
# secret EXPR: never the value, only null, empty or set.
secret() { echo "(SELECT CASE WHEN x IS NULL THEN N'null' WHEN DATALENGTH(x) = 0 THEN N'empty' ELSE N'set' END FROM (SELECT $1 AS x) s)"; }
# norm EXPR: an agent or job name with its trailing agent id or GUID replaced, so that two
# runs print the same value.
norm() { echo "(SELECT CASE WHEN x IS NULL THEN NULL  WHEN LEN(x) > 36 AND TRY_CONVERT(uniqueidentifier, RIGHT(x, 36)) IS NOT NULL THEN LEFT(x, LEN(x) - 36) + N'<guid>'  WHEN CHARINDEX(N'-', REVERSE(x)) > 1 AND RIGHT(x, CHARINDEX(N'-', REVERSE(x)) - 1) NOT LIKE N'%[^0-9]%' THEN LEFT(x, LEN(x) - CHARINDEX(N'-', REVERSE(x)) + 1) + N'<id>'  WHEN x LIKE N'syncobj[_]0x%' THEN N'syncobj_0x<hex>'  ELSE x END FROM (SELECT CONVERT(nvarchar(4000), $1) AS x) s)"; }
# sched COLUMN: the column of the agent job's schedule (#s), no-schedule when the job (#j)
# has none, no-job when there is no job. active_start_date of today prints as today.
sched() {
    local v="CONVERT(nvarchar(20), $1)"
    [ "$1" = active_start_date ] && v="CASE WHEN active_start_date = CONVERT(int, CONVERT(char(8), GETDATE(), 112)) THEN N'today' ELSE CONVERT(nvarchar(20), active_start_date) END"
    echo "ISNULL((SELECT TOP (1) $v FROM #s), (SELECT CASE WHEN COUNT(*) = 0 THEN N'no-job' ELSE N'no-schedule' END FROM #j))"
}
# switch NAME: the value of -NAME in the agent's step command (#st), absent, or no-job.
switch() {
    echo "ISNULL((SELECT CASE WHEN CHARINDEX(N' -$1 ', t) = 0 THEN N'absent' ELSE RTRIM(LTRIM(SUBSTRING(t, CHARINDEX(N' -$1 ', t) + DATALENGTH(N' -$1 ') / 2, CHARINDEX(N' -', t, CHARINDEX(N' -$1 ', t) + DATALENGTH(N' -$1 ') / 2) - CHARINDEX(N' -$1 ', t) - DATALENGTH(N' -$1 ') / 2))) END FROM (SELECT TOP (1) N' ' + CONVERT(nvarchar(4000), command) + N' -' AS t FROM #st) c), N'no-job')"
}
# switch_secret NAME: set or absent, never the value.
switch_secret() {
    echo "ISNULL((SELECT TOP (1) CASE WHEN CHARINDEX(N' -$1 ', N' ' + CONVERT(nvarchar(4000), command) + N' ') = 0 THEN N'absent' ELSE N'set' END FROM #st), N'no-job')"
}
# extra_switches: the agent step command (#st) minus the switches the agent procedures
# generate (-Publisher, -PublisherDB, -Publication, -Distributor, -DistributorSecurityMode,
# -Subscriber, -SubscriberDB, -SubscriberSecurityMode, -SubscriptionType, -Continuous):
# what @optional_command_line added, absent when nothing, no-job without a job. The
# command is split at " -", which does not occur inside the bracketed generated values.
extra_switches() {
    echo "ISNULL((SELECT ISNULL((SELECT STRING_AGG(N'-' + LTRIM(RTRIM(x.value)), N' ') FROM STRING_SPLIT(REPLACE(N' ' + CONVERT(nvarchar(4000), command), N' -', NCHAR(1)), NCHAR(1)) x
  WHERE LTRIM(RTRIM(x.value)) <> N'' AND LEFT(LTRIM(x.value) + N' ', CHARINDEX(N' ', LTRIM(x.value) + N' ') - 1) NOT IN (N'Publisher', N'PublisherDB', N'Publication', N'Distributor', N'DistributorSecurityMode', N'Subscriber', N'SubscriberDB', N'SubscriberSecurityMode', N'SubscriptionType', N'Continuous')), N'absent') FROM #st), N'no-job')" | tr '\n' ' '
}

# sched_map: the ten schedule parameters of an agent procedure.
sched_map() {
    cat <<EOF
@frequency_type|msdb.dbo.sysschedules.freq_type of the agent job|$(sched freq_type)
@frequency_interval|msdb.dbo.sysschedules.freq_interval of the agent job|$(sched freq_interval)
@frequency_relative_interval|msdb.dbo.sysschedules.freq_relative_interval of the agent job|$(sched freq_relative_interval)
@frequency_recurrence_factor|msdb.dbo.sysschedules.freq_recurrence_factor of the agent job|$(sched freq_recurrence_factor)
@frequency_subday|msdb.dbo.sysschedules.freq_subday_type of the agent job|$(sched freq_subday_type)
@frequency_subday_interval|msdb.dbo.sysschedules.freq_subday_interval of the agent job|$(sched freq_subday_interval)
@active_start_time_of_day|msdb.dbo.sysschedules.active_start_time of the agent job|$(sched active_start_time)
@active_end_time_of_day|msdb.dbo.sysschedules.active_end_time of the agent job|$(sched active_end_time)
@active_start_date|msdb.dbo.sysschedules.active_start_date of the agent job (today = the day of the run)|$(sched active_start_date)
@active_end_date|msdb.dbo.sysschedules.active_end_date of the agent job|$(sched active_end_date)
EOF
}

# The rows and the per-context counts.
rows=()
COUNTS=()
COUNT_SUM=0
# r ID RESULT DETAIL. campaign.sh rejects an R| line or field of exactly 256 characters as
# an nvarchar(max) cut by sqlcmd. These rows are assembled by the script from values that
# are nvarchar(4000) and checked not to be 256 characters long one by one (measure), so a
# row of that length is a real one of that length: it gets a trailing " (len)" marker
# instead of failing the run.
r() {
    local line="R|$1|$2|$3"
    if [ "${#line}" -eq 256 ] || [ "${#3}" -eq 256 ]; then line+=" (len)"; fi
    rows+=("$line")
}

# measure PROC CONTEXT MAP PREAMBLE CALL PASSED [P A D]
#   MAP      the map text (lines @parameter|column|expression)
#   PREAMBLE T-SQL run before the value query (fills the #tables)
#   CALL     the result of the call (ok, an error number, rcN), recorded in each row
#   PASSED   space-separated optional parameters the context passes
measure() {
    local proc=$1 ctx=$2 map=$3 pre=$4 call=$5 passed=" $6 " P=${7:-} A=${8:-} D=${9:-}
    optional_params "$proc"
    map=${map//\{P\}/$P}; map=${map//\{A\}/$A}; map=${map//\{D\}/$D}
    pre=${pre//\{P\}/$P}; pre=${pre//\{A\}/$A}; pre=${pre//\{D\}/$D}
    declare -A col expr
    local p desc e q out k v i
    while IFS='|' read -r p desc e; do
        [ -n "$p" ] || continue
        [ -z "${col[$p]+x}" ] || def_fail "map of $proc.$ctx names $p twice"
        col[$p]=$desc; expr[$p]=$e
    done <<<"$map"
    for p in "${!col[@]}"; do
        [[ " ${OPT_NAMES[*]} " == *" $p "* ]] || def_fail "map of $proc.$ctx names $p, which is not an optional parameter of sys.$proc"
    done
    q="SET NOCOUNT ON;
$pre
"
    local first=1
    for p in "${OPT_NAMES[@]}"; do
        [ -n "${col[$p]+x}" ] || def_fail "map of $proc.$ctx has no line for $p"
        [ "$first" = 1 ] || q+="UNION ALL "
        first=0
        q+="SELECT N'$p', ISNULL(REPLACE(REPLACE(REPLACE(CONVERT(nvarchar(4000), (${expr[$p]})), NCHAR(13), N' '), NCHAR(10), N' '), N'|', N'/'), N'null')
"
    done
    out=$(sql -b -h -1 <<<"$q" 2>&1) || def_fail "value query of $proc.$ctx failed: $(printf '%s\n' "$out" | grep -E '^Msg|^Sqlcmd' -A1 | head -n 4 | tr '\n' ' ')"
    declare -A val
    while IFS= read -r line; do
        line=${line%"${line##*[![:space:]]}"}
        [[ $line == @* ]] || continue
        k=${line%%|*}; v=${line#*|}
        val[$k]=$v
    done <<<"$out"
    for i in "${!OPT_NAMES[@]}"; do
        p=${OPT_NAMES[$i]}
        [ -n "${val[$p]+x}" ] || def_fail "$proc.$ctx: no value returned for $p"
        v=${val[$p]}
        # An empty string prints as '' (NULL prints as null).
        [ -n "$v" ] || v="''"
        [ "${#v}" -ne 256 ] || def_fail "$proc.$ctx: value of $p is 256 characters long, cut by sqlcmd"
        local flag=""
        [[ $passed == *" $p "* ]] && flag=" passed"
        r "D.$proc.$ctx.$p" "$v" "column=${col[$p]} declared=${OPT_DEFAULTS[$i]}${flag} call=$call"
    done
    COUNTS+=("$proc.$ctx=${#OPT_NAMES[@]}")
    COUNT_SUM=$((COUNT_SUM + ${#OPT_NAMES[@]}))
    echo "count $proc.$ctx: ${#OPT_NAMES[@]} optional parameters in sys.all_parameters"
}

# try_in DB STATEMENTS: runs STATEMENTS in DB, outside a transaction, inside TRY...CATCH.
# The statements may set @rc (EXEC @rc = ...). Sets TRY_RESULT to ok, the error number,
# or rcN for a procedure that returned N without raising an error, and TRY_MSG to the
# start of the error message (empty when ok). A refused replication procedure can leave a
# transaction open: it is rolled back.
TRY_RESULT=""; TRY_MSG=""
try_in() {
    local out line
    out=$(sql -b -h -1 <<<"SET NOCOUNT ON; USE [$1];
DECLARE @rc int = 0, @e nvarchar(20) = N'ok', @m nvarchar(4000) = N'';
BEGIN TRY
$2
IF @rc <> 0 SET @e = N'rc' + CONVERT(nvarchar(10), @rc);
END TRY
BEGIN CATCH
    SET @e = CONVERT(nvarchar(10), ERROR_NUMBER());
    SET @m = LEFT(REPLACE(REPLACE(REPLACE(ERROR_MESSAGE(), N'|', N'/'), NCHAR(13), N' '), NCHAR(10), N' '), 160);
END CATCH;
WHILE @@TRANCOUNT > 0 ROLLBACK;
SELECT N'#result|' + @e + N'|' + @m;" 2>&1) || def_fail "try_in $1 failed: $(printf '%s\n' "$out" | grep -E '^Msg|^Sqlcmd' -A1 | head -n 4 | tr '\n' ' ')"
    line=$(printf '%s\n' "$out" | grep '^#result|' | tail -n 1)
    [ -n "$line" ] || def_fail "try_in $1: no result line in: $(printf '%s\n' "$out" | tail -n 3 | tr '\n' ' ')"
    line=${line%"${line##*[![:space:]]}"}
    line=${line#\#result|}
    TRY_RESULT=${line%%|*}
    TRY_MSG=${line#*|}
    [[ $TRY_RESULT =~ ^(ok|[0-9]+|rc-?[0-9]+)$ ]] || def_fail "try_in $1: unexpected result $TRY_RESULT"
}

# stop_m_agents: stops the running agent jobs of m_ objects (distribution agents of m_
# subscriber databases, pull agents running in an m_ database, log readers of m_
# databases, snapshot agents of m_ publications) and waits until they have stopped. An
# agent dropped while it runs logs "The process was successfully stopped" after its agent
# row is gone, leaving an orphan history row (seen once in fix round 1 of Task 10).
stop_m_agents() {
    local jobs="SELECT CONVERT(uniqueidentifier, job_id) AS job_id FROM distribution.dbo.MSdistribution_agents WHERE local_job = 1 AND subscriber_db LIKE N'm\_%' ESCAPE N'\'
 UNION SELECT CONVERT(uniqueidentifier, job_id) FROM distribution.dbo.MSlogreader_agents WHERE publisher_db LIKE N'm\_%' ESCAPE N'\'
 UNION SELECT CONVERT(uniqueidentifier, job_id) FROM distribution.dbo.MSsnapshot_agents WHERE local_job = 1 AND publication LIKE N'm\_%' ESCAPE N'\'
 UNION SELECT job_id FROM msdb.dbo.sysjobsteps WHERE subsystem = N'Distribution' AND database_name LIKE N'm\_%' ESCAPE N'\'"
    local running="SELECT ja.job_id FROM msdb.dbo.sysjobactivity ja WHERE ja.session_id = (SELECT MAX(session_id) FROM msdb.dbo.syssessions) AND ja.start_execution_date IS NOT NULL AND ja.stop_execution_date IS NULL AND ja.job_id IN ($jobs)"
    # A job asked to stop while it is starting can keep running (seen in 12-contexts):
    # the stop is repeated until none runs, for up to 90 s.
    local i left
    for i in $(seq 1 18); do
        left=$(sql -b -h -1 -Q "SET NOCOUNT ON; DECLARE @j uniqueidentifier, @n int = 0;
DECLARE c CURSOR LOCAL FOR $running;
OPEN c; FETCH NEXT FROM c INTO @j;
WHILE @@FETCH_STATUS = 0 BEGIN SET @n += 1; BEGIN TRY EXEC msdb.dbo.sp_stop_job @job_id = @j; END TRY BEGIN CATCH END CATCH; FETCH NEXT FROM c INTO @j; END;
CLOSE c; DEALLOCATE c;
SELECT @n;" </dev/null 2>&1) || def_fail "cannot stop the m_ agent jobs: $left"
        left=$(printf '%s\n' "$left" | sed 's/[[:space:]]//g' | grep -v '^$' | tail -n 1)
        [ "$left" = 0 ] && return 0
        sleep 5
    done
    def_fail "m_ agent jobs still running after 90 s: $(sql_value "SELECT ISNULL(STRING_AGG(CONVERT(nvarchar(4000), j.name), N', '), N'none') FROM msdb.dbo.sysjobs j WHERE j.job_id IN ($running)" 2>&1)"
}

# value ID: the result field of a row already recorded.
value() { printf '%s\n' "${rows[@]}" | awk -F'|' -v id="$1" '$2 == id { print $3 }'; }
