# Lab

A SQL Server 2022 Developer container (CU27 on 2026-11-10) that is at once distributor, publisher and push subscriber, with SQL Agent enabled. It is the instance the measurements of `docs/analysis/step-1-analysis.md` and of the design `docs/superpowers/specs/2026-11-10-sqlrepl-plan-apply-design.md` are run on.

```
export MSSQL_SA_PASSWORD=...
lab/start.sh          # recreates the container repllab (127.0.0.1:11980) and runs setup.sql
```

`start.sh` creates the snapshot folder `/var/opt/mssql/data/ReplData` and gives it to `mssql`; `sp_adddistpublisher` refuses a working directory that does not exist (error 21037).

`setup.sql` builds:

- `SalesPub`: independent agent, `immediate_sync`, `concurrent` sync, a row filter (`FLTR_Customer`), a named synchronization view (`SYNC_Customer`), a column filter, a non-default `schema_option`, custom commands and a renamed destination (`Orders` → `OrdersCopy`);
- `SalesRef`: shared distribution agent, `native` sync, with a schema-only view article;
- push subscriptions of both to `SalesSub` on the same instance, and a user-defined distribution profile `lab-distrib`.

Export it:

```
SQLREPL_PASSWORD=$MSSQL_SA_PASSWORD sqlrepl export -publisher 'tcp:127.0.0.1,11980' \
    -distributor 'tcp:127.0.0.1,11980' -database Sales -user sa -param encrypt=disable
```

`-distributor` is needed because the distributor registered at the publisher is the container hostname, which does not resolve from the host.

Stop the container when done (`SHUTDOWN` through sqlcmd, then `podman rm repllab`): each instance takes 1 to 1.5 GB.

## The campaign

The scripts of `lab/campaign/` measure what the planner needs (items 1 to 13 of the design's "Measurement campaign"). They run through the runner, which keeps a results file only when the run can be trusted:

```
lab/campaign.sh 2022 lab/campaign/05-snapshot-flag.sh     # one script
lab/campaign.sh 2022 lab/campaign/*                       # the whole campaign
lab/distributor-defaults.sh 2022                          # run directly, it stops the lab
```

The runner's guards are described at the top of `campaign.sh`: the replication is alive (tracer tokens on `SalesPub` and `SalesRef`) before and after each script, no restart, exit status, a `TOTAL` line equal to the count, no cut row, no uncaught SQL error, no `m_` residue of any kind, and an export of `Sales` identical before and after. `lab/selftest.sh` checks each guard against a fixture that must fail it.

Results are in `lab/results/<version>/<script>.txt`, one `R|<case id>|<result>|<detail>` line per case and a `R|TOTAL|n` line. A result is cited by the file name and the case id, for example `05-snapshot-flag S7.O1`. The whole campaign ran on 2022 CU27 on 2026-11-10 and 2026-11-11; 2019 and 2025 have not run yet.

### Reading the results files

Some fields change from one run to the next without any change of behavior, and a diff of two runs must ignore them:

- `07-changes`: the job name suffix of the snapshot agent (`REPLLAB-Sales-m_p-1196` in `AGT.sp_changepublication_snapshot.snapshot_job_name`) and the profile id `m_prof_id=39` of the `PRF.*` rows are assigned by the server;
- `08-pull`: the agent ids (`distributor_agent=3430/type1` and `3431` in `P1.*`) and the `secret#<hash>` values of `P2.*`, which fingerprint a regenerated encrypted value;
- `15-snapshot-scope` and `16-snapshot-report-sources`: every duration is written `bucket(raw)`, for example `gen=ms<30000(3990)`, and offsets are raw. The buckets and the verdicts are what a rerun must reproduce; the raw numbers are there to be quoted and differ on every run;
- `13-transient`: `orphan_dist_history` is 0 or 1 when the distribution agent is still running at the drop (`T03` to `T06`, `T10`). It depends on whether the agent writes one more history row after its agent row is gone. `T04` showed both values across runs, so the value is a race, not an outcome.

The results files are never edited by hand: a field that needs a different reading is documented here.

### Planned and measured totals

The plan of the campaign announced a total for some scripts. Where the measured total differs, the controller added cases while the task was reviewed:

| Script | Planned | Measured | Why |
|---|---|---|---|
| `05-snapshot-flag` | 50 | 70 | states S6 (the operated article invalidated) and S7 (ready snapshot, undelivered subscription) added |
| `09-snapshot-pub` | the count | 110 | a ready `immediate_sync` snapshot publication (`SNAPI`) and a transactional twin for the command rows (`TWIN`) added |
| `10-init-modes` | 9 | 11 | re-creation from a fresh backup (`gap-fresh`) and from the subscriber's LSN (`gap-resume`) added |
| `14-filter-view` | 8 | 28 | the cases measured on an unsubscribed (`F*`), an active (`F*s`) and an undelivered (`F*u`) subscription, plus `F2b` and `F6r` |

The others match the plan: `01` 8, `02` 67, `03` 3, `04` 1, `06` 20, `13` 10, and the scripts whose plan said "the count" (`07` 75, `08` 42, `11` 554, `12` 70, `distributor-defaults` 39, `15` 158, `16` 27).

### Lab residue

Two things accumulate on the lab and no guard sees them, because they are not `m_` objects: the log of `Sales` grows (520 MB after the runs of 15 and 16, which insert and drop a 1,000,000-row table in a published database), and `distribution.dbo.MSrepl_errors` keeps the error rows of the agents the scripts made fail on purpose or by chance (10 rows after 15). Neither changes a result. `lab/start.sh` recreates the container and resets both.

The snapshot commands of dropped `m_` articles also stay in `distribution.dbo.MSrepl_commands` until the distribution cleanup removes them.

## Articles and the first measurements

`lab/campaign/01-articles.sql` (results `01-articles.txt`, cases `A1` to `A8`):

| # | Measure | Result |
|---|---|---|
| 1 | `sp_addpublication` without `sp_addpublication_snapshot` | `MSsnapshot_agents` has a row with `local_job = 0` and the `job_id` of a job that does not exist |
| 2 | default `schema_option` of a table article | `0x30073` (Learn says `0x30F3`; `0x80` primary key is not set, the primary key travels as the clustered index) |
| 3 | `schema_option` with `0x8` (timestamp as timestamp) | `sysarticles.status` gets `0x8` (column names in INSERT) and `0x20`, undocumented |
| 4 | `@filter_clause` in `sp_addarticle` alone | the clause is stored, no filter procedure is created |
| 5 | `sp_articlefilter` and `sp_articleview` with names | `type` stays 1: the `manual filter` / `manual view` types are not what tells a user-named object |
| 6 | `sp_articlecolumn @operation = 'drop'` | neither `type` nor `status` change |
| 7 | `sp_articlefilter` without `@filter_name`; `upd_cmd = 'SCALL'` without a procedure | errors 14043 and 15251: a filter procedure is always named by the user, and the CALL family needs a procedure name |
| 8 | `sysschemaarticles.pre_creation_cmd` for the default `drop` | 1, the same code as `sysarticles`; Learn's "1 = Delete, 2 = Drop" for schema articles is wrong for 1 |

Also seen while building the lab: SQL Server 2022 stores the generated command procedures schema-qualified (`CALL [dbo].[sp_MSins_dboCustomer]`), and the subscriber name in `syssubscriptions` is upper case (`REPLLAB`) while `@@SERVERNAME` is `repllab`. Server names must be compared without regard to case.

## The impact matrix

`lab/campaign/02-matrix.sql` (results `02-matrix.txt`, cases `P01` to `P38`, `A01` to `A23`, `F01` to `F06`) measures each `sp_changepublication`, `sp_changearticle`, `sp_articlefilter` and `sp_articlecolumn` change with the four flag combinations, each in a transaction rolled back, on `SalesPub` (`immediate_sync`, ready snapshot) and `SalesRef` (no `immediate_sync`). The tables are in section 5 of `docs/analysis/step-1-analysis.md`. The rows that surprised: the commands change online (`A06` to `A09`), `sp_articlecolumn` works on a subscribed article (`F04` to `F06`), and only `SalesPub` ever asks for `@force_invalidate_snapshot`.

## Adding an article and the filter clause

`lab/campaign/03-add-article.sh` (results `03-add-article.txt`, cases `C1` to `C3`) and `lab/campaign/04-filter-clause.sh` (results `04-filter-clause.txt`, case `F1`), on articles of their own:

| # | Measure | Result |
|---|---|---|
| 9 | add an article to an `immediate_sync` publication (`C1`) | refused without `@force_invalidate_snapshot = 1` (20607); the existing subscription is subscribed to it at once; the next snapshot covers the 3 articles, only the new one is delivered |
| 10 | add an article to a publication without `immediate_sync` (`C2`) | accepted with no flag; the subscription is not extended, `sp_addsubscription @article` is needed; the next snapshot covers the new article alone |
| 11 | `sp_addarticle` refused inside `TRY` (`C3`) | the transaction it opened stays open in the `CATCH` (`@@TRANCOUNT = 1`): the caller must roll back, otherwise what follows runs in it and is lost when the session ends |
| 12 | filter clause given to `sp_addarticle`, no `sp_articlefilter` (`04 F1`) | the snapshot is filtered, the changes are not: a row inserted later that fails the clause reaches the subscriber. The export warns about it |

## When the flags are needed

`lab/campaign/05-snapshot-flag.sh` (results `05-snapshot-flag.txt`) runs nine operations (`O1` add an article, `O2` drop one, `O3` `schema_option`, `O4` description, `O5` `alt_snapshot_folder`, `O6` `sync_method`, `O7` row filter, `O8` view, `O9` column) in seven snapshot states (`S1` to `S7`, described at the top of the script), each flag combination in a rolled-back transaction.

The condition for `@force_invalidate_snapshot` is `immediate_sync_ready = 1`, nothing else: `S1` and `S7` (ready) ask for it on every operation that touches the snapshot, `S2` (`immediate_sync` but never generated), `S5` and `S6` (generated, then invalidated) never do. The condition for `@force_reinit_subscription` is the subscription status of the operated article: it is asked when that article's subscription is at status 2 (`S3.O3`, `S5.O3` on the active sibling), and not when it is at status 1 (`S2`, `S4`, `S6.O3`, `S6.O7` to `S6.O9`). `O6` (`sync_method`) asks for it when any article is at status 2 (`S6.O6`). `O4` never needs a flag and `O5` never needs the reinit flag.

The row that surprised is `S7`: `sp_addsubscription` on an `immediate_sync` publication whose snapshot is ready sets the subscription to status 2 at once, before anything is delivered, so `S7` measures like `S1`. A status 1 with a ready snapshot (through `sp_reinitsubscription`) is not measured.

Seen while writing the script: a disabled agent job keeps running; `sp_stop_job` is needed.

## Drops and re-adds

`lab/campaign/06-structural.sh` (results `06-structural.txt`, cases `C1` to `C5`, each on `imm-conc`, `imm-native`, `nonimm-conc`, `nonimm-native`):

- `C1`: `sp_dropsubscription @article = 'all'` drops the whole subscription with no flag and leaves no subscription row, agent row or job.
- `C2`: the subscription to one article, then the article: `sp_droparticle` needs `@force_invalidate_snapshot = 1` exactly when `immediate_sync_ready = 1`.
- `C3`: an article dropped and added back is delivered alone; the marker row of the other article survives at the subscriber. On `immediate_sync` the existing subscription is extended by `sp_addarticle` itself (`extend=none`); without it, `sp_addsubscription` is needed.
- `C4`: an article added: same rule, and only the new table is bulk copied.
- `C5`: `sp_droppublication` after the drop of its subscriptions, no 18752 in one attempt, nothing left.

## Subscriptions, agents, profiles and the distributor

`lab/campaign/07-changes.sh` (results `07-changes.txt`) changes one property at a time, rolled back or restored, and records which system tables and jobs move:

- `SUB.*`: `sp_changesubscription` changes the distribution agent row only; the heterogeneous properties are refused with 14041.
- `SBR.*`: `sp_changesubscriber` writes `MSsubscriber_info` and `MSsubscriber_schedule` and touches no job, no job step and no agent row, although Learn says that every distribution task of the subscriber is updated.
- `AGT.*`: agent changes; `job_login` needs a valid Windows account (14529), `job_security_mode` is Managed Instance only (41989), `frequency_type` alone is refused (14278) while `frequency_type` with `frequency_interval` works.
- `PRF.*`: binding an agent to a profile works through `distribution.dbo.sp_update_agent_profile`, or the plain name when the current database is `distribution`; `msdb.dbo.sp_update_agent_profile` is refused with 21482 from anywhere.
- `DST.*`: `sp_changedistributiondb` retention values and `sp_changedistpublisher working_directory` change online; restoring `security_mode = 1` regenerates the stored publisher password; `trusted` is refused (21698).
- `SHR.after1`, `SHR.after2`: a shared distribution agent and its job survive the drop of the first of its two subscriptions and disappear with the last.

## Pull subscriptions

`lab/campaign/08-pull.sh` (results `08-pull.txt`):

- `P1.named`: `@subscription_type = N'pull'` at both ends gives a named pull subscription, delivered.
- `P1.omitted`: without `@subscription_type` at the subscriber, the subscriber records an anonymous subscription (type 2) while the publisher has a named pull, and the agent fails with 21084 ("does not allow anonymous subscriptions").
- `G1.orphan-guard`: the runner's orphan-job predicate flags a live pull job, harmless since the guard runs after each script only.
- `P2.*`: `sp_change_subscription_properties`. Learn does not list `distributor` and `memory_optimized`, which are accepted; `offload_agent` and `offload_server` are refused (21698); a NULL `dts_package_password` is refused with 21732, where Learn says it leaves the password unchanged; the `ftp_*` properties are accepted and ignored.
- `P3.*`: dropping at the subscriber first (`sp_droppullsubscription`, then `sp_dropsubscription` at the publisher) leaves nothing at any step. The other order leaves the pull agent running until the subscriber drop, logging "Agent message code 21021. The subscription does not exist."

## Snapshot publications

`lab/campaign/09-snapshot-pub.sh` with `09-snapshot-pub-matrix.sql` (results `09-snapshot-pub.txt`) replays the matrix on a snapshot publication without a ready snapshot (`SNAP.*`), with one (`SNAPI.*`, `immediate_sync`), and the command rows on a transactional twin (`TWIN.*`). On a snapshot publication the commands need a reinitialization (`SNAP.A06` to `SNAP.A09`, both flags on `SNAPI`) where the transactional twin changes them online (`TWIN.A01` to `TWIN.A04`); `concurrent` is refused (22547, `SNAP.P12`); initialization from backup is refused (18787, `SNAP.P06`). `SNAP.A22` and `SNAPI.A22` change `filter` to the same value only: pointing it at another publication's filter procedure ended the connection with an assertion (Msg 3624, severity 20) on 2022 CU27 while the script was written, eight times.

## Initialization without a snapshot

`lab/campaign/10-init-modes.sh` (results `10-init-modes.txt`) creates subscriptions by "replication support only" (`I1`), from a backup (`I2`) and from an LSN (`I3`), checks delivery, then drops and re-adds each while rows are inserted in the gap. The re-add with "replication support only" loses the gap rows silently (`I1.support-only.gap`, `missing=[111]`); re-adding with the original backup or LSN replays already delivered rows and fails on 14151 (`I2.backup.gap-original`, `I3.lsn.gap-original`); re-creating from a fresh `COPY_ONLY` backup (`I2.backup.gap-fresh`) or from the subscriber's `transaction_timestamp` (`I3.lsn.gap-resume`) delivers every gap row. `I3.lsn.create` shows that the plan's LSN formula was wrong (`brief_formula_matches=no`).

During the development of this script, a wrong LSN given to `initialize from lsn` was accepted silently and wrote `MSrepl_transactions` rows that moved the watermark of every idle distribution agent of the publisher database: the lab's own replication stopped without an error. The lab was recreated, and the runner gained its `alive` guard. An LSN must be checked (round trip, not beyond the end of the log, not before the backup) before the call.

## Defaults and execution contexts

`lab/campaign/11-defaults.sh` (results `11-defaults.txt`, rows `D.<procedure>.<context>.<parameter>`) calls each in-scope procedure with its required parameters only and reads what it stored for every optional parameter. A value written `pre-existing(...)` was there before the call and is not a default. `@subscriber_type` of `sp_addsubscription` is not measured, because the lab's subscriber is registered beforehand (`D.sp_addsubscription.push.@subscriber_type`). The context `table.non-dbo-schema` shows that an unqualified command procedure name is stored with `[dbo]` even for a source table in another schema (`@ins_cmd` given as `CALL m_ins` is stored as `CALL [dbo].[m_ins]`).

`lab/campaign/12-contexts.sh` (results `12-contexts.txt`, rows `X.<procedure>.<database>`) calls each procedure from `master`, `msdb`, `distribution`, the publication database and a plain database. The publication procedures need the publication database; `sp_addpullsubscription` is refused only in `master` (21481); `sp_add_agent_profile` and `sp_replicationdboption` work from anywhere.

`lab/distributor-defaults.sh` (results `distributor-defaults.txt`) runs the distributor procedures on a fresh container: `sp_adddistributor` needs `master` (5001 elsewhere), `sp_adddistributiondb` and `sp_adddistpublisher` run from any database. It stops the lab, so it runs outside the runner.

## Transient errors during drops

`lab/campaign/13-transient.sh` (results `13-transient.txt`, cycles `T01` to `T10`) creates and drops a publication ten times, in `Sales` and in a database of its own, with an own or a shared agent, stopped or running. No 1205 and no 18752 appeared, so the retry question stays open. Dropping the last publication of a database also drops its log reader, its job and its `MSpublisher_databases` row (`T02`, `T04`, `T06`, `T08`, `T10`); dropping with the distribution agent running can leave one history row whose agent is gone (see "Reading the results files").

## Filters, views and columns

`lab/campaign/14-filter-view.sh` with `14-filter-view-cases.sql` (results `14-filter-view.txt`) runs eight sequences (`F1` to `F8`, plus `F2b`) on an article without a subscription, with an active subscription (`s` suffix) and with an undelivered one (`u`), plus `F6r` (the reinit flag on the unsubscribed article). `sp_articlefilter` with a new clause leaves the view on the old one in every state (`F2b`, `F2bs`, `F2bu`). `sp_articleview` without a clause sets `filter_clause` to NULL while the filter procedure keeps filtering (`F4`). `sp_articlecolumn` rebuilds an existing view when the article has a subscription, at status 1 or 2 (`F6s`, `F6u`), and not when it has none (`F6`), even with the reinit flag (`F6r`); the reinit flag is asked only at status 2 (`F*s` against `F*u`).

## Snapshot scope and blocking

`lab/campaign/15-snapshot-scope.sh` (results `15-snapshot-scope.txt`, phases `A` to `F` described at the top of the script) is campaign item 12. The results that matter:

- `A.imm.*`: with `immediate_sync`, every `sync_method` regenerates every article and delivers only the new one. `A.non.*`: without it, every method generates only the new article, `concurrent` and `concurrent_c` included.
- Blocking, from writers updating one row every 50 ms on each table. Under `native` and `character` the generated tables are locked from shortly before the "Locking published tables" history line to the history's last line, about half of the run (`A.imm.native` 2044 ms of 3990, `A.imm.character` 3002 of 4920, `A.non.native` 3141 of 5290); tables the run does not generate are not locked (`A.non.native` m_t1 and m_t2 under 20 ms). Under `concurrent` the writers waited about 100 ms at the end of the run (`A.imm.concurrent`); under `database snapshot` about 200 ms near the start (`A.imm.dbsnap`, `F.imm_dbsnap_*`).
- `C.<method>.<op>`: which invalidating operation leaves a subscription awaiting a snapshot. Dropping an article, `alt_snapshot_folder`, `immediate_sync = false` and a `sync_method` change between `native`, `character` and `database snapshot` leave `immediate_sync_ready = 0` with nothing awaited.
- `D.*`: extending a subscription that a change has just marked for reinitialization. The refusals (14122, 14058 on `immediate_sync`, 14100 for a named article on `concurrent`) are static rules, not effects of the mark.
- `E.*`: the generation, with the distribution agent stopped, sets the subscription to status 2 and the article's active bit; nothing is delivered until the agent runs.
- `B.*`: the `-defer-full-snapshot` sequence of the design, with and without `allow_anonymous`, under `native` and `concurrent`, and the race of restoring `immediate_sync` without waiting.

The rows that surprised: the generation, not the delivery, sets status 2 (`E.generated_undelivered`); `sync_method` from `concurrent` to `concurrent_c` marks every subscription, like a change across to `native` (`D.non_concurrent.sync_method_probe`); and under `database snapshot` the delivery of a just-added article failed in some runs with "Could not find stored procedure 'dbo.sp_MSupd_dbom_t3'". The failure is in the round 1 results (`git show 8db6060:lab/results/2022/15-snapshot-scope.txt`, `A.imm.dbsnap`) and in two development runs (`A.non.dbsnap`); the committed run delivered everywhere, and the variants built to reproduce it (`F.dbsnap_*`, `F.imm_dbsnap_1` to `_3`) all delivered. Its cause is unknown.

## Sources of the snapshot report

`lab/campaign/16-snapshot-report-sources.sh` (results `16-snapshot-report-sources.txt`, rows `RS.<method>.<source>`) is campaign item 13, under `native`, `concurrent` and `database snapshot`:

- the snapshot history has per-article bulk copy and schema lines under every method, `concurrent` included (`RS.*.snapshot_history`);
- the distribution history has one "Bulk copied data into table" line per bcp partition, whose sums equal the source counts, and a "Delivered snapshot from the '...<timestamp>\' sub-folder" line naming the run's folder, for a shared agent too (`RS.*.distribution_history`);
- `sys.dm_os_enumerate_filesystem` lists the run's folder as `find` does, for `sa` and for a login with only `public` at the server and `SELECT` in `distribution` (`RS.*.filesystem_*`);
- the agent's sessions and their `program_name` (`RS.*.program_names`): the writer was blocked by the session named after the snapshot job under `native` and `database snapshot`; under `concurrent` no blocker was seen. A shared distribution agent's sessions are named `<instance>_<publisher_db>` (`repllab_Sales`) and cannot be told from another shared agent's;
- sampling every 250 ms sees the native lock wait (2376 of 2462 ms) where 1 s under-reads it; the 289 ms wait under `database snapshot` is under-read at 250 ms and missed at 1 s; under `concurrent` the writer's longest UPDATE (101 ms) held 24 ms of lock wait, the rest being a log flush (`RS.*.sampling_*`);
- `sp_startpublication_snapshot` on a running job returns 1 with `@@ERROR` 0 and nothing for `TRY...CATCH`, and prints "HResult 0x5606, Level 16, State 1" with the Agent's refusal, not a `Msg` line (`RS.*.start_running`);
- a login without `VIEW SERVER PERFORMANCE STATE` gets error 300 on `sys.dm_os_waiting_tasks`, and on `sys.dm_exec_requests` no error but its own session only (`RS.m_low.*`).

## Observed outside the campaign

Read on the lab on 2026-11-11 at 14:32 UTC, by read-only queries during the folding of the results into the design, not a campaign row. `SalesPub` (`immediate_sync`, snapshot agent every 5 minutes) had generated the folders `20261111142005`, `20261111142504` and `20261111143004` in the last 15 minutes, while its subscription, active with nothing awaited, last logged "Delivered snapshot from the 'unc\REPLLAB_SALES_SALESPUB\20261111101123\' sub-folder". On an `immediate_sync` publication, the latest generation folder and the last delivered folder therefore differ for a subscription that awaits nothing: the comparison of the two folders cannot by itself tell a pending delivery. In the same reading, the latest snapshot commands of `SalesPub`'s two articles in `distribution.dbo.MSrepl_commands` (`xact_seqno` `0x000000ED00007B580071`) were below the last `xact_seqno` of its distribution agent's history (`0x000000ED00007B70000B`): a comparison of sequence numbers gives the right answer for this delivered subscription. The undelivered case has not been read.
