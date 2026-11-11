#!/bin/bash
# The database each in-scope procedure must run from (campaign item 9, second part): each
# procedure of 11-defaults.sh, with valid parameters, executed from master, msdb,
# distribution, Sales and m_ctx (a user database the script creates, neither published nor
# subscribed). Run through lab/campaign.sh. The distributor procedures are measured by
# lab/distributor-defaults.sh on a fresh instance: on a configured lab they are refused
# from everywhere (14099, 14119).
#
# Rows: R|X.<procedure>.<database>|<ok, the error number, or rcN>|prereq=<..> undo=<..>
# msg=<start of the error message>. The procedure is called unqualified, so that it runs
# in the database of the row (sys procedures execute in the current database).
#
# Objects: in Sales the tables m_ct0 and m_ct, the publication m_cx (active, allow_pull,
# snapshot agent that never fires, article m_cperm on m_ct0); the databases m_ctx, m_cxsub1
# (push subscriber), m_cxsub2 (pull subscriber at the publisher), m_cxpub (target of
# sp_replicationdboption). Per procedure, what the call needs (prereq), the call, and what
# undoes it:
#   sp_addpublication            m_cx1; undo sp_droppublication in the database of the row
#   sp_addarticle                m_ca on dbo.m_ct in m_cx; undo sp_droparticle
#   sp_articlefilter             prereq article m_ca (Sales); filter m_cflt, id > 0; undo sp_droparticle
#   sp_articleview               prereq m_ca; view m_cview, id > 0; undo sp_droparticle
#   sp_articlecolumn             prereq m_ca; drop column a; undo sp_droparticle
#   sp_addsubscription.push      to m_cxsub1; undo sp_dropsubscription (Sales)
#   sp_addsubscription.pull      to m_cxsub2, pull; undo sp_dropsubscription (Sales)
#   sp_addpushsubscription_agent prereq push subscription to m_cxsub1 (Sales); undo sp_dropsubscription
#   sp_addpullsubscription       the database of the row is the subscriber; undo sp_droppullsubscription there
#   sp_addpullsubscription_agent prereq sp_addpullsubscription in the database of the row; undo sp_droppullsubscription
#   sp_addlogreader_agent        prereq for m_ctx: publish enabled; undo a publication added and
#                                dropped (removes the MSpublisher_databases row), publish disabled.
#                                From Sales, which has the lab's log reader, the call runs in a
#                                transaction rolled back.
#   sp_addpublication_snapshot   prereq publication m_cx2 (Sales), schedule that never fires; undo sp_droppublication
#   sp_add_agent_profile         m_cprof, agent type 3; undo sp_drop_agent_profile
#   sp_replicationdboption       publish on m_cxpub; undo publish false from master
# After every row a fingerprint of the state (m_ publications, articles and subscriptions of
# m_cx, distribution agent rows of the m_cx subscribers, msdb jobs, m_ profiles, the pull
# subscription tables and m_ objects of the five databases, publish flags of m_ctx and
# m_cxpub, MSpublisher_databases rows, log reader agents) must equal the one taken before
# the first row; the row records undo=differs otherwise, and the run fails.
#
# Asserted, exit 1 otherwise (rows on stderr): 70 rows (14 calls, sp_addsubscription push
# and pull counted apart, in 5 databases); every prereq run in Sales and every
# undo is ok; the fingerprint never differs; each procedure succeeds from the database it
# is designed for (Sales for the publication side, m_ctx for the pull subscriber side and
# the log reader of a newly published database, msdb for sp_add_agent_profile, master for
# sp_replicationdboption).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
. "$here/../lib.sh"
DEF_SCRIPT=12-contexts
. "$here/../defaults-lib.sh"

EXPECTED_ROWS=70
DBS="master msdb distribution Sales m_ctx"
MDBS="m_ctx m_cxsub1 m_cxsub2 m_cxpub"

cleaned=0
cleanup() {
    [ "$cleaned" = 1 ] && return
    cleaned=1
    local d
    ( stop_m_agents ) || true
    for d in $DBS; do
        # Two steps: a batch that names a missing MSreplication_subscriptions fails with 208.
        if [ "$(sql_value "SELECT CASE WHEN DB_ID(N'$d') IS NOT NULL AND OBJECT_ID(N'[$d].dbo.MSreplication_subscriptions') IS NOT NULL THEN 1 ELSE 0 END" 2>/dev/null)" = 1 ]; then
            sql -Q "SET NOCOUNT ON; USE [$d]; IF EXISTS (SELECT 1 FROM dbo.MSreplication_subscriptions WHERE publication = N'm_cx') BEGIN TRY DECLARE @s sysname = @@SERVERNAME; EXEC sp_droppullsubscription @publisher = @s, @publisher_db = N'Sales', @publication = N'm_cx'; END TRY BEGIN CATCH END CATCH; WHILE @@TRANCOUNT > 0 ROLLBACK;" </dev/null >&2 || true
        fi
    done
    sql <<'SQL' >&2 || true
SET NOCOUNT ON;
USE Sales;
DECLARE @p sysname;
DECLARE c CURSOR LOCAL FOR SELECT name FROM dbo.syspublications WHERE name LIKE N'm\_%' ESCAPE N'\';
OPEN c; FETCH NEXT FROM c INTO @p;
WHILE @@FETCH_STATUS = 0
BEGIN
    BEGIN TRY EXEC sp_dropsubscription @publication = @p, @article = N'all', @subscriber = N'all'; END TRY BEGIN CATCH END CATCH;
    WHILE @@TRANCOUNT > 0 ROLLBACK;
    BEGIN TRY EXEC sp_droppublication @publication = @p; END TRY BEGIN CATCH END CATCH;
    WHILE @@TRANCOUNT > 0 ROLLBACK;
    FETCH NEXT FROM c INTO @p;
END;
CLOSE c; DEALLOCATE c;
DROP TABLE IF EXISTS dbo.m_ct0, dbo.m_ct;
DROP PROCEDURE IF EXISTS dbo.m_cflt;
DROP VIEW IF EXISTS dbo.m_cview;
GO
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = N'm_ctx' AND is_published = 1)
    EXEC (N'USE m_ctx; BEGIN TRY EXEC sp_addpublication @publication = N''m_cxlr''; EXEC sp_droppublication @publication = N''m_cxlr''; END TRY BEGIN CATCH END CATCH; WHILE @@TRANCOUNT > 0 ROLLBACK;
USE master; BEGIN TRY EXEC sp_replicationdboption @dbname = N''m_ctx'', @optname = N''publish'', @value = N''false''; END TRY BEGIN CATCH END CATCH;');
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = N'm_cxpub' AND is_published = 1)
    EXEC (N'USE master; BEGIN TRY EXEC sp_replicationdboption @dbname = N''m_cxpub'', @optname = N''publish'', @value = N''false''; END TRY BEGIN CATCH END CATCH;');
GO
DECLARE @id int = (SELECT profile_id FROM msdb.dbo.MSagent_profiles WHERE profile_name = N'm_cprof');
IF @id IS NOT NULL EXEC msdb.dbo.sp_drop_agent_profile @profile_id = @id;
GO
DECLARE @j uniqueidentifier;
WHILE 1 = 1
BEGIN
    SET @j = (SELECT TOP (1) job_id FROM msdb.dbo.sysjobs WHERE name LIKE N'%-m\_%' ESCAPE N'\');
    IF @j IS NULL BREAK;
    EXEC msdb.dbo.sp_delete_job @job_id = @j;
END;
GO
DECLARE @d sysname, @i int, @s nvarchar(400);
DECLARE c CURSOR LOCAL FOR SELECT name FROM sys.databases WHERE name IN (N'm_ctx', N'm_cxsub1', N'm_cxsub2', N'm_cxpub');
OPEN c; FETCH NEXT FROM c INTO @d;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @i = 0;
    WHILE DB_ID(@d) IS NOT NULL AND @i < 20
    BEGIN
        SET @s = N'ALTER DATABASE ' + QUOTENAME(@d) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE ' + QUOTENAME(@d) + N';';
        BEGIN TRY EXEC (@s); END TRY
        BEGIN CATCH WAITFOR DELAY '00:00:02'; END CATCH;
        SET @i += 1;
    END;
    FETCH NEXT FROM c INTO @d;
END;
CLOSE c; DEALLOCATE c;
SQL
    podman exec repllab find /var/opt/mssql/data/ReplData/unc -mindepth 1 -maxdepth 1 -iname '*_m_*' -exec rm -rf {} + >&2 || true
}
trap cleanup EXIT

left=$(sql_value "SELECT (SELECT COUNT(*) FROM Sales.dbo.syspublications WHERE name LIKE N'm\_%' ESCAPE N'\') + (SELECT COUNT(*) FROM sys.databases WHERE name LIKE N'm\_%' ESCAPE N'\') + (SELECT COUNT(*) FROM Sales.sys.objects WHERE name LIKE N'm\_%' ESCAPE N'\') + (SELECT COUNT(*) FROM msdb.dbo.MSagent_profiles WHERE profile_name LIKE N'm\_%' ESCAPE N'\') + (SELECT COUNT(*) FROM distribution.dbo.MSpublisher_databases WHERE publisher_db LIKE N'm\_%' ESCAPE N'\')")
if [ "$left" != 0 ]; then
    echo "12-contexts: leftovers of an earlier run ($left); removing them and failing" >&2
    exit 1
fi

# The pull subscription tables and m_ objects of each database of the rows.
fp_dbs=""
for d in $DBS; do
    fp_dbs+=" N' $d=', (SELECT CONCAT(
        CASE WHEN OBJECT_ID(N'[$d].dbo.MSreplication_subscriptions') IS NULL THEN 0 ELSE 1 END,
        CASE WHEN OBJECT_ID(N'[$d].dbo.MSsubscription_properties') IS NULL THEN 0 ELSE 1 END,
        CASE WHEN OBJECT_ID(N'[$d].dbo.MSsubscription_agents') IS NULL THEN 0 ELSE 1 END,
        CASE WHEN OBJECT_ID(N'[$d].dbo.MSreplication_objects') IS NULL THEN 0 ELSE 1 END,
        N'/', (SELECT COUNT(*) FROM [$d].sys.objects WHERE name LIKE N'm\_%' ESCAPE N'\'))),"
done
fingerprint() {
    sql_value "SELECT CONCAT(
  N'pubs=', ISNULL((SELECT STRING_AGG(CONVERT(nvarchar(4000), name), N',') WITHIN GROUP (ORDER BY name) FROM Sales.dbo.syspublications WHERE name LIKE N'm\_%' ESCAPE N'\'), N''),
  N' articles=', (SELECT COUNT(*) FROM Sales.dbo.sysextendedarticlesview a JOIN Sales.dbo.syspublications p ON p.pubid = a.pubid WHERE p.name = N'm_cx'),
  N' subs=', (SELECT COUNT(*) FROM Sales.dbo.syssubscriptions s JOIN Sales.dbo.sysarticles a ON a.artid = s.artid JOIN Sales.dbo.syspublications p ON p.pubid = a.pubid WHERE p.name = N'm_cx'),
  N' dist_agents=', (SELECT COUNT(*) FROM distribution.dbo.MSdistribution_agents WHERE subscriber_db LIKE N'm\_cx%' ESCAPE N'\' OR publication LIKE N'm\_%' ESCAPE N'\'),
  N' jobs=', (SELECT COUNT(*) FROM msdb.dbo.sysjobs),
  N' profiles=', (SELECT COUNT(*) FROM msdb.dbo.MSagent_profiles WHERE profile_name LIKE N'm\_%' ESCAPE N'\'),
  $fp_dbs
  N' published=', (SELECT STRING_AGG(CONCAT(name, N':', is_published), N',') WITHIN GROUP (ORDER BY name) FROM sys.databases WHERE name IN (N'm_ctx', N'm_cxpub')),
  N' pubdbs=', (SELECT COUNT(*) FROM distribution.dbo.MSpublisher_databases),
  N' logreaders=', (SELECT COUNT(*) FROM distribution.dbo.MSlogreader_agents))"
}

sql -b <<'SQL' >&2
SET NOCOUNT ON;
CREATE DATABASE m_ctx; CREATE DATABASE m_cxsub1; CREATE DATABASE m_cxsub2; CREATE DATABASE m_cxpub;
GO
USE Sales;
CREATE TABLE dbo.m_ct0 (id int PRIMARY KEY, a nvarchar(20));
CREATE TABLE dbo.m_ct (id int PRIMARY KEY, a nvarchar(20));
EXEC sp_addpublication @publication = N'm_cx', @status = N'active', @allow_pull = N'true';
EXEC sp_addpublication_snapshot @publication = N'm_cx', @frequency_type = 1, @active_start_date = 99991231,
     @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;
EXEC sp_addarticle @publication = N'm_cx', @article = N'm_cperm', @source_owner = N'dbo', @source_object = N'm_ct0';
SQL
baseline=$(fingerprint)
echo "baseline: $baseline"

ADD_ARTICLE="EXEC @rc = sp_addarticle @publication = N'm_cx', @article = N'm_ca', @source_owner = N'dbo', @source_object = N'm_ct';"
DROP_ARTICLE="EXEC @rc = sp_droparticle @publication = N'm_cx', @article = N'm_ca', @force_invalidate_snapshot = 1;"
ADD_PUSH="EXEC @rc = sp_addsubscription @publication = N'm_cx', @subscriber = @@SERVERNAME, @destination_db = N'm_cxsub1';"
DROP_PUSH="EXEC @rc = sp_dropsubscription @publication = N'm_cx', @article = N'all', @subscriber = @@SERVERNAME, @destination_db = N'm_cxsub1';"
DROP_PULLSIDE="EXEC @rc = sp_dropsubscription @publication = N'm_cx', @article = N'all', @subscriber = @@SERVERNAME, @destination_db = N'm_cxsub2';"
ADD_PULLSUB="EXEC @rc = sp_addpullsubscription @publisher = @@SERVERNAME, @publisher_db = N'Sales', @publication = N'm_cx';"
DROP_PULLSUB="DECLARE @s sysname = @@SERVERNAME; EXEC @rc = sp_droppullsubscription @publisher = @s, @publisher_db = N'Sales', @publication = N'm_cx';"
LR_UNDO="EXEC @rc = sp_addpublication @publication = N'm_cxlr'; IF @rc = 0 EXEC @rc = sp_droppublication @publication = N'm_cxlr';"

rows=()
r() { rows+=("R|$1|$2|$3"); }
bad=0
control() { echo "12-contexts: control failed: $*" >&2; bad=1; }

# row PROC DB PREREQ_DB PREREQ CALL UNDO_DB UNDO [UNDO_ALWAYS]
#   PREREQ_DB / UNDO_DB: a database, or "here" for the database of the row; PREREQ may be
#   empty. The undo runs when the call succeeded, or always when UNDO_ALWAYS is 1 (it then
#   removes what the prereq created).
row() {
    local proc=$1 db=$2 pdb=$3 pre=$4 stmt=$5 udb=$6 undo=$7 always=${8:-0}
    local pres=none res msg ures=none fp
    [ "$pdb" = here ] && pdb=$db
    [ "$udb" = here ] && udb=$db
    if [ -n "$pre" ]; then
        try_in "$pdb" "$pre"; pres=$TRY_RESULT
        if [ "$pdb" = Sales ] && [ "$pres" != ok ]; then control "X.$proc.$db: prereq in Sales gave $pres ($TRY_MSG)"; fi
    fi
    try_in "$db" "$stmt"; res=$TRY_RESULT; msg=$TRY_MSG
    if [ "$res" = ok ] || [ "$always" = 1 ] || { [ "$always" = prereq ] && [ "$pres" = ok ]; }; then
        stop_m_agents
        try_in "$udb" "$undo"; ures=$TRY_RESULT
        [ "$ures" = ok ] || control "X.$proc.$db: undo in $udb gave $ures ($TRY_MSG)"
    fi
    fp=$(fingerprint)
    if [ "$fp" != "$baseline" ]; then
        control "X.$proc.$db: state differs after the undo: $fp"
        ures+="(state differs)"
    fi
    r "X.$proc.$db" "$res" "prereq=$pres undo=$ures msg=${msg:-none}"
}

for db in $DBS; do
    row sp_addpublication "$db" "" "" "EXEC @rc = sp_addpublication @publication = N'm_cx1';" here "EXEC @rc = sp_droppublication @publication = N'm_cx1';"
    row sp_addarticle "$db" "" "" "$ADD_ARTICLE" Sales "$DROP_ARTICLE"
    row sp_articlefilter "$db" Sales "$ADD_ARTICLE" "EXEC @rc = sp_articlefilter @publication = N'm_cx', @article = N'm_ca', @filter_name = N'm_cflt', @filter_clause = N'id > 0';" Sales "$DROP_ARTICLE" 1
    row sp_articleview "$db" Sales "$ADD_ARTICLE" "EXEC @rc = sp_articleview @publication = N'm_cx', @article = N'm_ca', @view_name = N'm_cview', @filter_clause = N'id > 0';" Sales "$DROP_ARTICLE" 1
    row sp_articlecolumn "$db" Sales "$ADD_ARTICLE" "EXEC @rc = sp_articlecolumn @publication = N'm_cx', @article = N'm_ca', @column = N'a', @operation = N'drop';" Sales "$DROP_ARTICLE" 1
    row sp_addsubscription.push "$db" "" "" "$ADD_PUSH" Sales "$DROP_PUSH"
    row sp_addsubscription.pull "$db" "" "" "EXEC @rc = sp_addsubscription @publication = N'm_cx', @subscriber = @@SERVERNAME, @destination_db = N'm_cxsub2', @subscription_type = N'pull';" Sales "$DROP_PULLSIDE"
    row sp_addpushsubscription_agent "$db" Sales "$ADD_PUSH" "EXEC @rc = sp_addpushsubscription_agent @publication = N'm_cx', @subscriber = @@SERVERNAME, @subscriber_db = N'm_cxsub1', @job_login = NULL, @job_password = NULL, @subscriber_security_mode = 1;" Sales "$DROP_PUSH" 1
    row sp_addpullsubscription "$db" "" "" "$ADD_PULLSUB" here "$DROP_PULLSUB"
    # The undo runs when the prereq or the call created the subscription.
    row sp_addpullsubscription_agent "$db" here "$ADD_PULLSUB" "DECLARE @srv sysname = @@SERVERNAME; EXEC @rc = sp_addpullsubscription_agent @publisher = @srv, @publisher_db = N'Sales', @publication = N'm_cx', @job_login = NULL, @job_password = NULL;" here "$DROP_PULLSUB" prereq
    lr_call="EXEC @rc = sp_addlogreader_agent @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;"
    if [ "$db" = Sales ]; then
        # The lab's own log reader: a refused call in a transaction rolled back.
        row sp_addlogreader_agent "$db" "" "" "BEGIN TRAN; $lr_call" here "SELECT 1;"
    elif [ "$db" = m_ctx ]; then
        row sp_addlogreader_agent "$db" master "EXEC @rc = sp_replicationdboption @dbname = N'm_ctx', @optname = N'publish', @value = N'true';" "$lr_call" here \
            "$LR_UNDO IF @rc = 0 EXEC @rc = master.sys.sp_replicationdboption @dbname = N'm_ctx', @optname = N'publish', @value = N'false';" prereq
    else
        row sp_addlogreader_agent "$db" "" "" "$lr_call" here "$LR_UNDO"
    fi
    row sp_addpublication_snapshot "$db" Sales "EXEC @rc = sp_addpublication @publication = N'm_cx2';" "EXEC @rc = sp_addpublication_snapshot @publication = N'm_cx2', @frequency_type = 1, @active_start_date = 99991231, @job_login = NULL, @job_password = NULL, @publisher_security_mode = 1;" Sales "EXEC @rc = sp_droppublication @publication = N'm_cx2';" 1
    row sp_add_agent_profile "$db" "" "" "DECLARE @pid int; EXEC @rc = sp_add_agent_profile @profile_id = @pid OUTPUT, @profile_name = N'm_cprof', @agent_type = 3;" msdb \
        "DECLARE @id int = (SELECT profile_id FROM msdb.dbo.MSagent_profiles WHERE profile_name = N'm_cprof'); EXEC @rc = msdb.dbo.sp_drop_agent_profile @profile_id = @id;"
    row sp_replicationdboption "$db" "" "" "EXEC @rc = sp_replicationdboption @dbname = N'm_cxpub', @optname = N'publish', @value = N'true';" master \
        "EXEC @rc = sp_replicationdboption @dbname = N'm_cxpub', @optname = N'publish', @value = N'false';"
done

field() { printf '%s\n' "${rows[@]}" | awk -F'|' -v id="$1" '$2 == id { print $3 }'; }
[ "${#rows[@]}" = "$EXPECTED_ROWS" ] || control "${#rows[@]} rows, expected $EXPECTED_ROWS"
for id in sp_addpublication.Sales sp_addarticle.Sales sp_articlefilter.Sales sp_articleview.Sales sp_articlecolumn.Sales \
          sp_addsubscription.push.Sales sp_addsubscription.pull.Sales sp_addpushsubscription_agent.Sales \
          sp_addpullsubscription.m_ctx sp_addpullsubscription_agent.m_ctx sp_addlogreader_agent.m_ctx \
          sp_addpublication_snapshot.Sales sp_add_agent_profile.msdb sp_replicationdboption.master; do
    [ "$(field "X.$id")" = ok ] || control "X.$id is '$(field "X.$id")', expected ok"
done

cleanup
if [ "$bad" != 0 ]; then
    for row in "${rows[@]}"; do echo "row: $row" >&2; done
    exit 1
fi
for row in "${rows[@]}"; do printf '%s\n' "$row"; done
echo "R|TOTAL|${#rows[@]}"
