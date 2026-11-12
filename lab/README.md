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

Results are in `lab/results/<version>/<script>.txt`, one `R|<case id>|<result>|<detail>` line per case and a `R|TOTAL|n` line. A result is cited by the file name and the case id, for example `05-snapshot-flag S7.O1`. The whole campaign ran on 2022 CU27 on 2026-11-10 and 2026-11-11. On 2019 CU32 and 2025 CU10 only `17-parameters` has run (2026-11-12), with every guard passing, the `export` guard included: this plan's export read the lab's `Sales` on both versions, identically before and after. The other scripts have not run on those versions.

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
| `17-parameters` | 316 | 316 | the parameters counted on 2026-11-11 for the plan; the script lists them (2019 CU32: 307, 2025 CU10: 319, "Procedure parameters") |
| `18-reverse` | 45 | 45 | the reverse direction of each property `02-matrix` and `05-snapshot-flag` measured away from its default, in three states (`I` 20, `N` 19, `P` 3, and a state row each) |
| `19-profiles` | 11 | 11 | the profile procedures Ruling R6 of plan 3 rests on |

The others match the plan: `01` 8, `02` 67, `03` 3, `04` 1, `06` 20, `13` 10, and the scripts whose plan said "the count" (`07` 75, `08` 42, `11` 1781 (554 before plan 3 Task 2 added the contexts below), `12` 70, `distributor-defaults` 39, `15` 158, `16` 27).

### Lab residue

Two things accumulate on the lab and no guard sees them, because they are not `m_` objects: the log of `Sales` grows (520 MB after the runs of 15 and 16, which insert and drop a 1,000,000-row table in a published database), and `distribution.dbo.MSrepl_errors` keeps the error rows of the agents the scripts made fail on purpose or by chance (10 rows after 15). Neither changes a result. `lab/start.sh` recreates the container and resets both.

The snapshot commands of dropped `m_` articles also stay in `distribution.dbo.MSrepl_commands` until the distribution cleanup removes them.

Two known gaps of the residue guard (`campaign.sh`, the file check near line 133), not fixed: it looks for `*_m_*` under `ReplData/unc` and `m_*` under `data`, so a run folder left under the alternate folder `/var/opt/mssql/data/ReplAlt` that scripts 02, 05, 09 and 15 set (`ReplAlt/unc/REPLLAB_..._M_...`) is not seen; and it counts no database user, so an `m_` principal left in `distribution`, `msdb` or `Sales` (16 creates `m_low` in `distribution` and drops it) is not seen either. Both were absent when the final review of the branch checked them. Close them, with a selftest fixture, before the 2019 and 2025 replays.

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

`lab/campaign/11-defaults.sh` (results `11-defaults.txt`, rows `D.<procedure>.<context>.<parameter>`) calls each in-scope procedure with its required parameters only and reads what it stored for every optional parameter. A value written `pre-existing(...)` was there before the call and is not a default. In the `push` and `pull` contexts `@subscriber_type` reads `pre-existing(0)`, because the lab's subscriber is registered beforehand (`D.sp_addsubscription.push.@subscriber_type`); the single row `D.sp_addsubscription.push.fresh-subscriber.@subscriber_type` measures it on `m_freshsub`, a name registered nowhere before the call: the call is accepted, registers the subscriber with `MSsubscriber_info.type` 0 (SQL Server) and adds its `sys.servers` row. The cleanup needs both `sp_dropsubscriber` and `sp_dropserver`: without the second, the `sys.servers` row stays (the break step of plan 3 Task 2 showed the residue guard failing on it). The context `table.non-dbo-schema` shows that an unqualified command procedure name is stored with `[dbo]` even for a source table in another schema (`@ins_cmd` given as `CALL m_ins` is stored as `CALL [dbo].[m_ins]`).

The destination owner of an article whose source is not in `dbo` (formerly the observation `O16`) is measured by the contexts `<kind>.nondbo.<method>` and `<kind>.nondbo.snapshot-pub.<method>`: the kinds `table`, `view-schema-only`, `proc-schema-only`, `func-schema-only` on `m_s.m_t`, `m_s.m_v`, `m_s.m_p`, `m_s.m_f`, under each `sync_method` of a transactional publication (`native`, `character`, `concurrent`, `concurrent_c`, `dbsnap` for `database snapshot`, `dbsnap_c` for `database snapshot character`) and the four a snapshot publication takes. `@destination_owner` is the source schema `m_s` under `native`, `concurrent`, `dbsnap` and `dbsnap_c`, and NULL under `character` and `concurrent_c`, for every kind and on both publication types (`D.sp_addarticle.<kind>.nondbo[.snapshot-pub].<method>.@destination_owner`). `database snapshot character`, which `O16` had not measured, keeps the source schema although it is a character mode: the NULL follows `character` and `concurrent_c`, not the character format. The context `snapshot-pub` of `sp_addpublication_snapshot` reads the snapshot agent of a snapshot publication created with the default schedule.

The statuses that plan 3's state prediction rests on are single rows on `m_pa_ext` (`native`, independent agent, `allow_pull`): a push subscription created with `@sync_type = 'replication support only'` is at status 2 at once (`D.sp_addsubscription.push.rso.@status`); a pull subscription registered at the publisher and extended to a second article by `sp_addsubscription @article = <article>, @subscription_type = 'pull', @sync_type = 'automatic'` gets a status 1 row of type pull, and still one distribution agent row (`D.sp_addsubscription.extend.pull.@status`, `.@subscription_type`, `.agents`); the replication support only subscription extended with `@subscription_type = 'push', @sync_type = 'replication support only'` gets a status 2 row of `sync_type` 2 (`D.sp_addsubscription.extend.rso.@status`).

`lab/campaign/12-contexts.sh` (results `12-contexts.txt`, rows `X.<procedure>.<database>`) calls each procedure from `master`, `msdb`, `distribution`, the publication database and a plain database. The publication procedures need the publication database; `sp_addpullsubscription` is refused only in `master` (21481); `sp_add_agent_profile` and `sp_replicationdboption` work from anywhere.

`lab/distributor-defaults.sh` (results `distributor-defaults.txt`) runs the distributor procedures on a fresh container: `sp_adddistributor` needs `master` (5001 elsewhere), `sp_adddistributiondb` and `sp_adddistpublisher` run from any database. It stops the lab, so it runs outside the runner.

## Transient errors during drops

`lab/campaign/13-transient.sh` (results `13-transient.txt`, cycles `T01` to `T10`) creates and drops a publication ten times, in `Sales` and in a database of its own, with an own or a shared agent, stopped or running. No 1205 and no 18752 appeared, so the retry question stays open. Dropping the last publication of a database also drops its log reader, its job and its `MSpublisher_databases` row (`T02`, `T04`, `T06`, `T08`, `T10`); dropping with the distribution agent running can leave one history row whose agent is gone (see "Reading the results files").

## Filters, views and columns

`lab/campaign/14-filter-view.sh` with `14-filter-view-cases.sql` (results `14-filter-view.txt`) runs eight sequences (`F1` to `F8`, plus `F2b`) on an article without a subscription, with an active subscription (`s` suffix) and with an undelivered one (`u`), plus `F6r` (the reinit flag on the unsubscribed article). `sp_articlefilter` with a new clause leaves the view on the old one in every state (`F2b`, `F2bs`, `F2bu`). `sp_articleview` without a clause sets `filter_clause` to NULL while the filter procedure keeps filtering (`F4`). `sp_articlecolumn` rebuilds an existing view when the article has a subscription, at status 1 or 2 (`F6s`, `F6u`), and not when it has none (`F6`), even with the reinit flag (`F6r`); the reinit flag is asked only at status 2 (`F*s` against `F*u`).

## Snapshot scope and blocking

`lab/campaign/15-snapshot-scope.sh` (results `15-snapshot-scope.txt`, phases `A` to `F` described at the top of the script) is campaign item 12. The results that matter:

- `A.imm.*`: with `immediate_sync`, every `sync_method` regenerates every article and delivers only the new one. `A.non.*`: without it, every method generates only the new article, `concurrent` and `concurrent_c` included.
- Blocking, from writers updating one row every 50 ms on each table. Under `native` and `character` the generated tables are locked from shortly before the "Locking published tables" history line to the history's last line, between a third and two thirds of the run (`A.imm.native` 2044 ms of 3990, `A.imm.character` 3002 of 4920, `A.non.native` 3141 of 5290, `A.non.character` 1235 of 3220); tables the run does not generate are not locked (`A.non.native` m_t1 and m_t2 under 20 ms). Under `concurrent` the writers waited about 100 ms at the end of the run (`A.imm.concurrent`); under `concurrent_c` they waited 207 ms together about 1.9 s after the run's last history line (`A.imm.concurrent_c`, one row); under `database snapshot` about 200 ms near the start (`A.imm.dbsnap`, `F.imm_dbsnap_*`).
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

## Procedure parameters

`lab/campaign/17-parameters.sql` (results `17-parameters.txt`, rows `R|<procedure>.<parameter>|<type>(<max_length>)|output=<0|1> id=<parameter_id>`) lists the parameters of the 18 procedures that create configuration (the list is in plan 2, "Rulings made in this plan"), read from `sys.all_parameters` for the procedures of the `sys` schema, ordered by procedure then `parameter_id`. It is read-only: it creates nothing and touches no lab object. Plan 2 maps every listed parameter to the YAML model, and `TestParametersCovered` reads this file.

On SQL Server 2022 CU27 it lists 316 parameters: `sp_add_agent_parameter` 3, `sp_add_agent_profile` 6, `sp_addarticle` 32, `sp_adddistpublisher` 11, `sp_adddistributiondb` 17, `sp_adddistributor` 6, `sp_addlogreader_agent` 8, `sp_addpublication` 49, `sp_addpublication_snapshot` 22, `sp_addpullsubscription` 8, `sp_addpullsubscription_agent` 45, `sp_addpushsubscription_agent` 31, `sp_addsubscription` 42, `sp_articlecolumn` 11, `sp_articlefilter` 7, `sp_articleview` 10, `sp_replicationdboption` 5, `sp_update_agent_profile` 3.

On SQL Server 2019 CU32 (15.0.4500.2) it lists 307, every one also listed on 2022. The nine 2022 adds: `sp_adddistributor` `@security_mode` and `@multi_subnet_failover` (4 parameters instead of 6), `@job_security_mode` of `sp_addlogreader_agent`, `sp_addpublication_snapshot`, `sp_addpullsubscription_agent` and `sp_addpushsubscription_agent`, and `sp_addsubscription` `@subscriber_security_mode`, `@subscriber_login`, `@subscriber_password` (39 instead of 42).

On SQL Server 2025 CU10 (17.0.5035.5) it lists 319: the 316 of 2022 and three parameters of `sp_adddistributor` (9 instead of 6), `@encrypt_distributor_connection`, `@trust_distributor_certificate` and `@host_name_in_distributor_certificate` (listed `nvarchar(20)`, `nvarchar(20)`, `nvarchar(510)`: `max_length` is in bytes, so `nvarchar(10)`, `nvarchar(10)`, `nvarchar(255)` as the definition declares them), placed before `@multi_subnet_failover`. Where they are stored was read from the 2025 definitions, not measured: `sp_adddistributor` passes them to `sys.sp_MSrepl_concat_encryption_params`, whose text is not visible to `sa` (`OBJECT_ID` is NULL, `sp_helptext` has no text, `sys.all_objects` does not list it), and appends the result, then `User ID=<login>;`, to the provider string of `repl_distributor`, only when `sys.sp_is_featureswitch_enabled N'ConfigureEncryptionDuringTranReplLinkedServerCreation'` returns 1 (that procedure is hidden too, and a direct call is error 2812). `sp_changedistributor_property` names the keys: it finds `Encrypt=`, `TrustServerCertificate=` and `HostNameInCertificate=` in `sys.servers.provider_string` with a case-insensitive `PATINDEX`, and replaces or appends `<key>=<value>;` with the value as given. The export reads those three keys (`distributor.link_encrypt`, `link_trust_server_certificate`, `link_host_name_in_certificate`, nil when absent). The lab's distributor is set up without them, and its provider string is NULL on 2025, so whether the feature switch is on, and the exact form `sp_MSrepl_concat_encryption_params` writes, are not measured: open for the 2025 support claim. The Learn page of `sp_adddistributor` differs from the listing on two points: it gives `@trust_distributor_certificate` as `nvarchar(5)` (the definition declares `nvarchar(10)`), and says `@encrypt_distributor_connection` "can't be NULL" while the definition defaults it to NULL; it also dates `@multi_subnet_failover` from 2025 CU8, while 2022 CU27 has it.

## Reverse directions

`lab/campaign/18-reverse.sh` (results `18-reverse.txt`, rows `RV.<state>.<case>` with the four flag cells, and `RV.<state>.state`) measures the change back to the default of the properties that `02-matrix` and `05-snapshot-flag` measured only away from it. Three publications on `dbo.m_rv_t1`, each case run with the four flag combinations in a rolled-back transaction:

- `I` (`m_rv_i`): `immediate_sync`, independent agent, `native`, every property of the cases at its non-default value, a push subscription to `m_rv_sub`, snapshot delivered and ready (ready 1, status 2, the state of `05` `S1`);
- `N` (`m_rv_n`): the same without `immediate_sync`, the independent agent and `allow_subscription_copy` (ready 0, status 2);
- `P` (`m_rv_p`): `allow_push` false, `allow_pull` true, `status` inactive, no article, no subscription.

Results. No reverse change asks for `@force_reinit_subscription`. On `I`, the properties of the snapshot's location and scripts ask for `@force_invalidate_snapshot` in this direction too (`alt_snapshot_folder`, `pre_snapshot_script`, `post_snapshot_script` set to NULL or empty, `snapshot_in_defaultfolder` true, and the article's `creation_script` NULL or empty: `f00=20607,f10=ok,f01=20607,f11=ok`); every other case, and every case on `N` and `P`, is `ok` in all four cells: `replicate_ddl` 1, `allow_pull`, `allow_initialize_from_backup`, `allow_subscription_copy`, `replicate_partition_switch` and `allow_drop` set to false, `replicate_partition_switch` false then true, `allow_partition_switch` false after `replicate_partition_switch` false, the article's `fire_triggers_on_snapshot` false and `status` `no column names` or `parameters`, and on `P` `status` active and `allow_push` true, then false again (`RV.P.allow_push_false`, the change with no push subscription).

What surprised was the setup, not the rows: on Linux the distribution agent cannot apply a snapshot that has a pre- or post-snapshot script. It fails with "Failed to obtain the SQL Server utilities installation path from the registry" (it runs the scripts through the command-line utilities it looks up in the Windows registry), retries, and the snapshot is never delivered. The script therefore creates `m_rv_i` and `m_rv_n` without the two snapshot scripts and the creation script, delivers, sets the three with `@force_invalidate_snapshot = 1` (which leaves the subscriptions at status 2), and generates `m_rv_i`'s snapshot again so that it is ready. A publication with a pre- or post-snapshot script cannot initialize a subscription on a Linux distributor.

## Agent profile changes

`lab/campaign/19-profiles.sql` (results `19-profiles.txt`, rows `PF.<case>`) runs from `master`; each case creates the distribution profile `m_prof` (`sp_add_agent_profile @agent_type = 3, @profile_type = 1`) in its own transaction, makes its call, reads back `msdb.dbo.MSagent_profiles` and `MSagent_parameters`, and rolls back (`PF.create_default` and `PF.copy_after_user_default` share one transaction). Every result is the one Ruling R6 of plan 3 expects:

- `PF.copied_parameters`: the new profile gets the 12 parameters of the template, `MIN(profile_id)` of the system distribution profiles (`Default agent profile` on the lab, which is also the default), names and values equal;
- `PF.change_missing_parameter`: `sp_change_agent_parameter` of `-PacketSize`, which the copy lacks, returns 0 and adds no row: a misspelt name is silent;
- `PF.change_description`, `PF.change_parameter` (`-CommitBatchSize` 200), `PF.add_parameter` (`-PacketSize` 8192, a name only `Distribution Profile for OLEDB streaming` has), `PF.drop_parameter` (`-QueryTimeout`, 11 parameters left) and `PF.drop_unused` are accepted and change exactly that row;
- `PF.add_copied_parameter`: `sp_add_agent_parameter` of a copied name is refused with 20067;
- `PF.create_default`: `sp_add_agent_profile @default = 1` makes the new profile the only default of the type and clears `def_profile` of the previous one;
- `PF.copy_after_user_default`: with that user profile the default and its `-CommitBatchSize` at 300, a profile created next still copies the template (`-CommitBatchSize` 100), not the default;
- `PF.change_default`: `sp_change_agent_profile @property = 'default'` is refused with 21183.

## Observed outside the campaign

Read on the lab on 2026-11-11 at 14:32 UTC, by read-only queries during the folding of the results into the design, not a campaign row. `SalesPub` (`immediate_sync`, snapshot agent every 5 minutes) had generated the folders `20261111142005`, `20261111142504` and `20261111143004` in the last 15 minutes, while its subscription, active with nothing awaited, last logged "Delivered snapshot from the 'unc\REPLLAB_SALES_SALESPUB\20261111101123\' sub-folder". On an `immediate_sync` publication, the latest generation folder and the last delivered folder therefore differ for a subscription that awaits nothing: the comparison of the two folders cannot by itself tell a pending delivery. In the same reading, the latest snapshot commands of `SalesPub`'s two articles in `distribution.dbo.MSrepl_commands` (`xact_seqno` `0x000000ED00007B580071`) were below the last `xact_seqno` of its distribution agent's history (`0x000000ED00007B70000B`): a comparison of sequence numbers gives the right answer for this delivered subscription. The task 12 review then read the same tables between two scheduled runs: new snapshot commands written at 14:45:09 stayed beyond the agent's history `xact_seqno` until its next history write, so that comparison reports a delivered subscription as awaiting while the agent has not written, and, by inference, for as long as the agent is stopped.

A reading at 14:54 UTC tested the window the 2019 source of `sp_MSget_repl_commands` applies, `xact_seqno` between `MSsubscriptions.subscription_seqno` and `ss_cplt_seqno` of the article: for `SalesPub`'s two articles the window is `0x0000002A00000C500045` to `0x0000002A00000C78007E`, it holds 14 and 11 old snapshot commands, all below the agent's history `xact_seqno`, and every other snapshot command of those articles, those of the scheduled runs included (up to `0x000000EE000000E00071`), lies beyond it, none before it (a second reading a few minutes later: 248 and 242 commands beyond, 0 before). Restricted to that window, the test says nothing is awaited whatever the agent's watermark. The undelivered case has not been read.

A reading at 15:52 UTC, during the fold of the design review, compared the names of `SalesPub`'s run folders with its snapshot agent history (`MSsnapshot_history`) and the distributor clock. The folder `20261111154504` belongs to the run whose "Starting agent" line was written at 15:45:02.647 and its "Initializing" line at 15:45:04.817; `20261111155004` to the run of 15:50:03.260 and 15:50:05.433. A run folder is named after the distributor's clock, to the second, between those two lines; the lab's local time is UTC, so whether the name is local time or UTC is not known. `sys.dm_os_enumerate_filesystem` gives these folders no creation time (it reads 1601-01-01), so the name is the only time a folder carries. Two runs, one publication: an observation, not a campaign row.

### Runs by the design reviewers and the controller

The design review of 2026-11-11 ran its own scenarios on `repllab` (2022 CU27), on objects named `rv_` that each reader created and removed. They are not campaign rows: each was run once, by hand. The spec cites them by the identifier below. The readers are the five seats of the panel on `d076e0d` (Mistral Large, GLM, codex directive, codex neutral, Claude), the fix review of `190003f`, and the controller, the session that ran the panel and checked findings itself. Their reports were session files and are not kept, so the table is the record of each run: what was run and what was seen. Campaign items 14, 15, 18, 19 and 20 of the design turn the entries into result rows.

| Id | Reader | What was run | What was seen |
|---|---|---|---|
| O1 | Mistral | non-`immediate_sync` `character` publication, distribution agent stopped: `sp_addarticle rv_t3` (no flag), `sp_addsubscription @article = N'rv_t3'`, one snapshot run | article status 17 (active bit set), subscription row status 2, no delivery after the mark, subscriber table absent (Msg 208) |
| O2 | Claude | `-defer-full-snapshot` sequence on an `immediate_sync` `native` publication, `t4` added, generated and delivered to two subscriptions (100 rows each) | the agent's "Bulk copied" and "Delivered snapshot" rows kept the old `xact_seqno` `0x0000002A000009800011000000030000`; the history caught up 3.5 minutes later with an idle row; the subscriber's `MSreplication_subscriptions.transaction_timestamp` already had the new value; 2 of 14 start rows of agent 3 carried `xact_seqno` 0x0 |
| O3 | GLM, Claude | `immediate_sync` `native` publication, `allow_anonymous` false, two runs | after run 2 the `-1` virtual row had the new window, the `-2` row kept run 1's |
| O4 | GLM | the `S7` recipe (subscriber database offline, `sp_addsubscription`, agent started implicitly then stopped) on two publications | on one, the subscription's window, the history watermark and the "Delivered snapshot" line (`...\20261111152405\`) all named run 2, generated after the subscription was added while run 1 was the only one; the window is written at activation by `sp_MSupdate_subscription` |
| O5 | Claude, codex directive, GLM, Mistral | the windowed test of item 14 with the history watermark, agents stopped: a delivered subscription and one more run; the `S7` path; an added article generated and not delivered | 0 commands beyond the watermark for the delivered one (the unrestricted count was 8 and 5); 8 for `S7`; 5 for the added article |
| O6 | codex directive, codex neutral | a subscription added to a ready `immediate_sync` publication, its agent job stopped (codex directive) or its subscriber database offline (codex neutral) | `immediate_sync_ready` 1, subscription status 2 at once; subscriber table count 0; `delivered_lines=0` |
| O7 | Mistral, codex directive | after a `sync_method` change from or to `concurrent` that marked every row: `sp_addarticle` with no flag on `immediate_sync`; `sp_addarticle` and a named `sp_addsubscription` on `native` | every call accepted, every article at status 1; no seat ran the snapshot that follows |
| O8 | Mistral | `immediate_sync` `concurrent`, after `sp_addarticle @force_invalidate_snapshot = 1`, `sp_addsubscription` by name, then with `'all'` | 14100 by name, 14058 with `'all'` |
| O9 | Mistral | non-`immediate_sync` publication, subscription added, snapshot never run (every row at status 1): `sync_method` to `concurrent`, then back to `native`, both with no flag | both accepted, statuses stayed 1 |
| O10 | Mistral | non-`immediate_sync` `native` publication, `sync_method` to `database snapshot` with no flag, in a transaction rolled back | accepted, `sync_method` read 5 inside the transaction, statuses unchanged |
| O11 | codex neutral | subscription to one article of two (`@article = N'rv_q8n2kd_a'`), then `sp_dropsubscription @article = N'all'`, `independent_agent` false, `sp_addsubscription @article = N'all'` | both articles subscribed |
| O12 | Claude, Mistral | Claude: `concurrent_c` publication (300,000 and 1,000 rows), writers updating one row every 50 ms, a sampler of `LCK%` waits every 50 ms, two runs. Mistral: `immediate_sync` `concurrent_c` publication (512,000 rows), one writer, three runs on the loaded container | Claude: 68 to 260 ms of `LCK_M_IX` near the start (blocker the snapshot job's session), 72 to 97 ms just before the last history line, and in run 1 a stall of 252 to 284 ms 4.9 s after the last line with no lock wait sampled. Mistral: in run 2 the writer's longest `UPDATE`, 939 ms, ended 8.4 s after the last history line |
| O13 | Claude, controller | push `sp_addsubscription` alone, then `sp_addpushsubscription_agent` (controller, on `rv_ctl9a`) | the first call prints "The distribution agent job has been implicitly created and will run under the SQL Server Agent Service Account" and starts the job, which delivered about 5 s later (Claude); the second returns 0 and updates the same job, its schedule changed from continuous to the one given and back (controller) |
| O14 | Claude, controller, fix review | drops of publications with their log reader running | Claude: two Msg 18752 from `sp_droppublication` under load, the log reader blocked over 200 s. Controller: two Msg 18752 from `sys.sp_replcmds` during the drop of `rv_ctl9a` on an idle lab, the drop completed; reproduced in the second fix round, two messages, drop completed. Fix review: eight publications of one database dropped one by one, only the last raised 18752, twice, return code 0, `@@TRANCOUNT` 0, publication and log reader agent gone |
| O15 | Claude | `immediate_sync` restored after the generation of step 3 and before any delivery, both agents disabled, `native` | both subscriptions received the new article alone, `immediate_sync_ready` stayed 0 |
| O16 | GLM, fix review, controller | `sp_addarticle` with a non-`dbo` `@source_owner` and no `@destination_owner`, then `sysschemaarticles.dest_owner` (or `sysarticles.dest_owner` for a table) | GLM: the source schema for a view and a procedure on a transactional and on a snapshot publication, and for a table on the snapshot publication (the report does not give the method, so the default `native` is assumed, not shown). Fix review: the source schema under `native` (view, function, procedure), `concurrent` and `database snapshot` (view); NULL under `character` and `concurrent_c` (view, function, procedure), and under `character` on a snapshot publication (view). Controller, second fix round: the source schema under `native` and NULL under `character`, for a view and a table. Now measured as campaign rows: `11-defaults` `D.sp_addarticle.<kind>.nondbo.<method>.@destination_owner` and `D.sp_addarticle.<kind>.nondbo.snapshot-pub.<method>.@destination_owner` (the source schema under `native`, `concurrent`, `dbsnap`, `dbsnap_c`; NULL under `character`, `concurrent_c`), which the cost table cites instead of this observation |
| O17 | fix review | `sp_addarticle @force_invalidate_snapshot = 1` on an `immediate_sync` publication while a run was held at "Locking published tables"; `sp_articlefilter` with both flags at the end of a run on a `native` publication; `sp_addsubscription` during a held run | Msg 21854, `@@TRANCOUNT` 0; Msg 21861 then 14070, the filter procedure kept its old clause; `sp_addsubscription` returned after 18 s, when the run ended |
| O18 | fix review | `concurrent` publication without `immediate_sync`, log reader job stopped, snapshot generated | publisher: subscription status 2, article status 17; distributor `MSsubscriptions`: status 3; the agent logged "The concurrent snapshot for publication ... is not available because it has not been fully generated or the Log Reader Agent is not running to activate it"; subscriber table absent; once the log reader ran, status 2 and delivery |
| O19 | fix review | a publication with `@alt_snapshot_folder = N'/var/opt/mssql/data/rv_q7x2kd_alt'`; a publication whose name has a space; six snapshot runs | the "Delivered snapshot" line read `unc\REPLLAB_RV_Q7X2KD_P_RV_Q7X2KD_AL\20261111162904\` while the files were under the alternate folder; the space is kept in the folder name; in the six runs, each folder was named between the run's "Starting agent" and "Initializing" lines |
| O20 | the session that applied the third fix round | an msdb job `rv_j8k2pq` with one `WAITFOR DELAY '00:00:20'` step, created disabled: `sp_start_job`, then `sp_update_job @enabled = 1` and `@enabled = 0` while it ran | `sp_start_job` returned 0 and the disabled job ran; disabling it while it ran did not stop it, and it ended "The job succeeded"; the job was deleted |
| O21 | controller | `immediate_sync` publication `rv_jd` with a snapshot agent on a five-minute schedule, its job disabled with `sp_update_job @enabled = 0`: `sp_startpublication_snapshot`, then `sp_changepublication_snapshot` with a new schedule | `sp_startpublication_snapshot` returned 0, `@@ERROR` 0, and the disabled job ran (12 history rows); after the schedule change the job was still disabled; the drop of the database's last publication printed two Msg 18752 and completed |
