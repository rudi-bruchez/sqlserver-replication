# sqlrepl plan 1: rename and measurement campaign

> For agentic workers: REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

Goal: rename `replcfg` to `sqlrepl`, then measure on SQL Server 2022 every replication behavior the planner needs and the spec leaves "to confirm", with scripts that run unchanged on 2019 and 2025.

Architecture: the rename is mechanical Go and docs work. The campaign is a set of self-cleaning measurement scripts under `lab/campaign/`, run by one runner, `lab/campaign.sh`, that guards every run: no leftover object, an unchanged export of the lab's own replication, no instance restart, and a result count that matches what the script announces. Results are committed as text under `lab/results/2022/`, and the last task folds them into the documentation the planner (plan 3) will be written from.

Tech stack: Go 1.26.5 (existing module, no new dependency), bash, T-SQL through `sqlcmd` in the podman container, SQL Server 2022 Developer.

Spec: `docs/superpowers/specs/2026-11-10-sqlrepl-plan-apply-design.md`, sections "Renaming" and "Measurement campaign". Background: `docs/analysis/step-1-analysis.md` (section 5, the matrix), `lab/README.md` (rows 1 to 12), `CLAUDE.md`.

This is the first of four plans. Plan 2 (model and export extension), plan 3 (planner) and plan 4 (apply) are written after this one has run, from its results: the cost table and several strategies of the spec depend on them.

## Global Constraints

- Everything written in the repository (code, comments, docs, commit messages, results) is in English.
- Documents: no bold, no em dash or en dash, titles that announce their subject without a conclusion or a count.
- Commit messages: prose that says why; no `Co-Authored-By`, `Generated with` or any other attribution trailer.
- No new Go dependency. `gofmt -l .` prints nothing, `go vet ./...` passes.
- The Go module path stays `github.com/rudi-bruchez/sqlserver-replication`.
- One SQL Server container at a time on this machine (memory): the lab `repllab`, `127.0.0.1:11980`, `MSSQL_MEMORY_LIMIT_MB=4096`. A task that needs a second instance (Task 10) stops nothing it did not start and removes what it starts.
- The `sa` password comes from `MSSQL_SA_PASSWORD`, loaded by `set -a; . ~/Sources/Repos/atelier/livres-informatiques/optimiser-sql-server/edition-2026/harnais/.env; set +a`, passed to `sqlcmd` as `SQLCMDPASSWORD`, never with `-P`, never printed.
- Every object a campaign script creates is named with the prefix `m_` (tables, publications, databases, profiles, views, procedures, backup files), and the script removes it before it ends.
- The lab's own objects (`Sales`, `SalesSub`, `SalesPub`, `SalesRef`, their articles, subscriptions, agents) are only changed inside a transaction rolled back in the same batch.
- A refused replication procedure leaves its transaction open (lab row 11, two levels for `sp_droparticle`): every case ends with `IF @@TRANCOUNT > 0 ROLLBACK`.
- `sp_addsubscription` refuses to run inside a transaction (15002): cases that add subscriptions run on `m_` objects, outside a transaction, and clean up.
- When the task is done, the lab is stopped with `SHUTDOWN WITH NOWAIT` (never `podman stop`), and `podman ps` is reported.
- If a measurement contradicts this plan, the spec or the analysis, record what was measured and say so in the task report. Do not adjust the script until it agrees with the document.

## Result format

Every campaign script prints its results as lines that start with `R|`, and nothing it prints for any other purpose starts that way:

```
R|<case id>|<result>|<detail>
R|TOTAL|<number of R lines above, TOTAL excluded>
```

`<case id>` is unique within the script and stable across versions (`S1.O3`, `C2.native-nonimm`). `<result>` is `ok`, an error number, a measured value, or for a flag matrix the four cells `f00=…,f10=…,f01=…,f11=…` (`@force_invalidate_snapshot`, `@force_reinit_subscription`). `<detail>` is free text without `|` or a newline. A T-SQL script builds its rows in a table variable and prints them with one `SELECT` at the end, so that a case that fails still produces its row.

## Review Focus

1. A result read before an agent has finished (snapshot not yet generated, distribution not yet delivered): a fixed `sleep` makes the measurement depend on machine load. Scripts wait on a predicate over agent history, with a timeout that fails the run. Pinned by `selftest.sh` case "wait times out" (Task 2).
2. The instance restarting during a run (it happened at 2 GB under five reviewers): objects vanish and later cases measure an empty lab without error. The runner compares `tempdb` `create_date` before and after. Pinned by `selftest.sh` case "restart detected" (Task 2).
3. A script that stops at its first error and reports a short list as if complete. `sqlcmd` runs without `-b`, each case is wrapped in `TRY…CATCH`, and the runner fails when the `TOTAL` line is missing or disagrees with the count. Pinned by `selftest.sh` case "total mismatch" (Task 2).
4. A connection failure that prints a `Sqlcmd: Error` line and exits 0, leaving a results file with zero cases. The runner fails on zero `R|` lines and on any line matching `^Sqlcmd: Error|^Msg 18456`. Pinned by `selftest.sh` case "no results" (Task 2).
5. A case that leaves an object or an open transaction behind and changes what the next script measures. The runner's residue query (Task 2) and the export comparison catch objects; the `@@TRANCOUNT` rule catches the transaction. Pinned by `selftest.sh` case "residue" (Task 2).

---

### Task 1: Rename replcfg to sqlrepl

Files:
- Move: `cmd/replcfg/` to `cmd/sqlrepl/` (`main.go`, `conn.go`, `conn_test.go`)
- Modify: `cmd/sqlrepl/main.go` (package comment, `usage`, error prefix, `-user` help, `os.Getenv`)
- Modify: `cmd/sqlrepl/conn.go:44` (`app name`), `cmd/sqlrepl/conn_test.go:41`
- Modify: `internal/reader/reader_test.go:36-42`
- Modify: `CLAUDE.md`, `README.md`, `lab/README.md`, `lab/setup.sql:1`

Interfaces:
- Produces: binary `sqlrepl` built by `go build ./cmd/sqlrepl`; environment variables `SQLREPL_PASSWORD` (export password) and `SQLREPL_TEST_DSN` (live query test); `app name` connection parameter `sqlrepl`.

- [ ] Step 1: Change the test expectation first: in `cmd/replcfg/conn_test.go:41` expect `q.Get("app name") != "sqlrepl"`.
- [ ] Step 2: Run `go test ./cmd/replcfg/` and see it fail on the app name.
- [ ] Step 3: `git mv cmd/replcfg cmd/sqlrepl`; replace every `replcfg` in the `cmd/sqlrepl` files with `sqlrepl` and `REPLCFG_PASSWORD` with `SQLREPL_PASSWORD`; in `internal/reader/reader_test.go` replace `REPLCFG_TEST_DSN` with `SQLREPL_TEST_DSN`.
- [ ] Step 4: Update `CLAUDE.md`, `README.md`, `lab/README.md` and `lab/setup.sql` the same way. In `CLAUDE.md`, the status paragraph says the spec and this plan exist and names their paths.
- [ ] Step 5: Verify, in one shell:

```
go build ./cmd/sqlrepl && go vet ./... && test -z "$(gofmt -l .)" && go test ./... && \
grep -rn 'replcfg\|REPLCFG' --include=*.go --include=*.md --include=*.sh --include=*.sql . | grep -v '^./docs/'
```

Expected: build, vet and tests pass; the grep prints nothing (the spec and plan under `docs/` keep the old name where they describe the rename).
- [ ] Step 6: Commit.

### Task 2: Campaign runner and its self-test

Files:
- Modify: `lab/start.sh` (version argument)
- Create: `lab/lib.sh`, `lab/campaign.sh`, `lab/selftest.sh`, `lab/selftest/` (fixture scripts)
- Create: `lab/.gitignore` (`.bin/`)

Interfaces:
- Produces:
  - `lab/start.sh [2019|2022|2025]`: default `2022`; image `mcr.microsoft.com/mssql/server:<version>-latest`; container `repllab`, port 11980, 4096 MB, then `setup.sql` as today.
  - `lab/lib.sh`, sourced by shell scripts: `sql [sqlcmd args...]` (runs `sqlcmd` in `repllab` with `-S localhost -U sa -C -W -s '|'`, no `-b`); `sql_value QUERY` (prints the single value, trimmed); `wait_until TIMEOUT_SECONDS QUERY` (polls every 5 s until `QUERY` returns `1`, returns 1 with a message on stderr at timeout).
  - `lab/campaign.sh VERSION SCRIPT...`: for each script (`.sql` run with `-i`, `.sh` executed), writes `lab/results/VERSION/<script basename without extension>.txt` containing a first line `# <@@VERSION first line>` then the script's `R|` lines; exits non-zero naming the guard that failed.
  - The guards, all checked per script: (1) at least one `R|` line other than `TOTAL`; (2) a `TOTAL` line equal to the count; (3) no line matching `^Sqlcmd: Error|^Msg 18456`; (4) the residue query returns 0: count of `sys.databases`, `Sales` objects, `syspublications`, `msdb.dbo.sysjobs`, `msdb.dbo.MSagent_profiles` and `distribution.dbo.MSpublications` rows whose name starts with `m_`; (5) `sqlrepl export` of `Sales` (binary built into `lab/.bin/sqlrepl`) identical before and after; (6) `tempdb` `create_date` unchanged.

- [ ] Step 1: Write `lab/selftest/` fixtures, each a few lines of T-SQL or shell:
  - `good.sql`: prints `R|a|ok|` and `R|TOTAL|1`;
  - `total-mismatch.sql`: prints two `R|` cases and `R|TOTAL|3`;
  - `no-results.sql`: prints nothing starting with `R|`;
  - `residue.sql`: creates table `Sales.dbo.m_left` and prints `R|a|ok|`, `R|TOTAL|1`;
  - `wait-timeout.sh`: sources `lib.sh`, calls `wait_until 10 "SELECT 0"`, prints `R|a|ok|`, `R|TOTAL|1` only if it returned 0;
  - `restart.sh`: runs `SHUTDOWN WITH NOWAIT`, `podman start repllab`, waits for `SELECT 1`, prints `R|a|ok|`, `R|TOTAL|1`.
- [ ] Step 2: Write `lab/selftest.sh`: runs `campaign.sh selftest` once per fixture, expects exit 0 for `good.sql` and non-zero for every other one, prints `PASS <fixture>` or `FAIL <fixture>` per line and exits non-zero if any line is `FAIL`; removes `Sales.dbo.m_left` and `lab/results/selftest/` at the end.
- [ ] Step 3: Run `lab/selftest.sh` before `campaign.sh` exists. Expected: it fails (command not found), not a false PASS.
- [ ] Step 4: Write `lab/lib.sh`, `lab/campaign.sh`, the `start.sh` version argument and `lab/.gitignore`.
- [ ] Step 5: In one shell: load the password, `lab/start.sh 2022`, `lab/selftest.sh`. Expected: six lines, `PASS good.sql`, `PASS total-mismatch.sql`, `PASS no-results.sql`, `PASS residue.sql`, `PASS wait-timeout.sh`, `PASS restart.sh`, exit 0. Any other number of lines means the runner or the self-test is wrong.
- [ ] Step 6: Break one guard on purpose: comment out the `tempdb` comparison in `campaign.sh`, rerun `lab/selftest.sh`. Expected: `FAIL restart.sh` and exit non-zero; five PASS out of six is the success of this step. Restore the line, rerun, six PASS.
- [ ] Step 7: Commit.

### Task 3: Existing measurements under the runner

Files:
- Move and convert: `lab/measure-articles.sql` to `lab/campaign/01-articles.sql`, `lab/measure-matrix.sql` to `lab/campaign/02-matrix.sql`, `lab/measure-add-article.sh` to `lab/campaign/03-add-article.sh`, `lab/measure-filter-clause.sh` to `lab/campaign/04-filter-clause.sh`
- Modify: `lab/README.md` (script names)
- Create: `lab/results/2022/01-articles.txt` … `04-filter-clause.txt`

Interfaces:
- Consumes: `campaign.sh`, `lib.sh` (Task 2).
- Produces: the convention every later script follows, on known measurements.

- [ ] Step 1: Convert each script to the result format and to `m_` objects. Their case lists stay those of lab rows 1 to 12: `01-articles` 8 cases (rows 1 to 8), `02-matrix` 67 cases (one per existing case, cells as today), `03-add-article` 3 cases (rows 9, 10, 11; on publications `m_imm` and `m_nonimm` of its own, not `SalesPub`/`SalesRef`), `04-filter-clause` 1 case (row 12, on `m_` objects). The `.sh` scripts replace their fixed `sleep` with `wait_until`.
- [ ] Step 2: Run `lab/campaign.sh 2022 lab/campaign/0[1-4]-*` with the lab started. Expected: exit 0, `R|TOTAL|8`, `67`, `3`, `1`.
- [ ] Step 3: Compare with `lab/README.md` rows 1 to 12 and with the matrix of analysis section 5. Expected: the same results. A difference is reported, not reconciled.
- [ ] Step 4: Commit scripts and results.

### Task 4: Snapshot flag condition (campaign item 1)

Files:
- Create: `lab/campaign/05-snapshot-flag.sh`, `lab/results/2022/05-snapshot-flag.txt`

Interfaces:
- Consumes: `lib.sh`, `campaign.sh`.
- Produces: rows `S<n>.O<m>` read by Task 12.

Five publication states, each a publication of its own with tables `m_t1`, `m_t2` and a push subscription to database `m_sub`, reached by running the agents and waiting on their history:

| State | Publication |
|---|---|
| S1 | `immediate_sync = 1`, snapshot generated and delivered |
| S2 | `immediate_sync = 1`, snapshot agent never run |
| S3 | `immediate_sync = 0`, snapshot delivered |
| S4 | `immediate_sync = 0`, subscription added, snapshot not yet run |
| S5 | `immediate_sync = 1`, snapshot delivered, then invalidated by a forced `sp_changearticle schema_option` and not regenerated |

Nine operations, each run in a rolled-back transaction once per flag combination the procedure accepts (two for `sp_addarticle` and `sp_droparticle`, which only take `@force_invalidate_snapshot`; four for the others): O1 `sp_addarticle` of a new table `m_t3`; O2 `sp_dropsubscription @article = 'm_t2'` then `sp_droparticle 'm_t2'`; O3 `sp_changearticle schema_option` to `0x000000000803509F`; O4 `sp_changearticle description` (control, expected online); O5 `sp_changepublication alt_snapshot_folder`; O6 `sp_changepublication sync_method`; O7 `sp_articlefilter` add on `m_t1`; O8 `sp_articleview` with that clause; O9 `sp_articlecolumn` drop of a column of `m_t1`.

- [ ] Step 1: Write the script; one row per state and operation, 45 rows, each `f00=…,f10=…` (two cells) or four cells; also record `immediate_sync_ready` per state as rows `S<n>.ready` (5 rows): `R|TOTAL|50`.
- [ ] Step 2: Run it through `campaign.sh 2022`. Expected: exit 0 and `R|TOTAL|50`.
- [ ] Step 3: Check the controls: `S1.O3` needs `f10` or `f11` (20607 at `f00`, as `SalesPub` in the matrix); `S3.O3` is accepted without the invalidate flag (as `SalesRef`); every `O4` row is `ok` in all cells. If a control disagrees, stop and report: the states were not reached.
- [ ] Step 4: Commit.

### Task 5: Structural operations (campaign items 2, 3, 4)

Files:
- Create: `lab/campaign/06-structural.sh`, `lab/results/2022/06-structural.txt`

Interfaces:
- Consumes: `lib.sh`; the flag findings of Task 4 decide which flags each case passes, and the script records which ones it passed.
- Produces: rows `C<n>.<kind>` read by Task 12.

Four publication kinds, built fresh for each case with tables `m_t1`, `m_t2`, a delivered snapshot and an active push subscription to `m_sub`: `imm-conc` (`immediate_sync = 1`, `concurrent`), `imm-native`, `nonimm-conc`, `nonimm-native`.

Cases, each on each kind (5 cases, 20 rows): C1 drop the whole subscription with `sp_dropsubscription @article = N'all'`: result, rows left in `syssubscriptions`, distribution agent row and job left; C2 drop the subscribed article `m_t2` (`sp_dropsubscription @article`, then `sp_droparticle` with the flags Task 4 found): result and flags; C3 drop `m_t2` and add it back: which tables the next snapshot bulk-copies (distribution history), subscription status of `m_t2`, rows of `m_t2` at the subscriber; C4 add `m_t3` and extend the subscription (`@article = 'm_t3'` on native kinds, `'all'` on concurrent kinds, auto on `immediate_sync`): tables bulk-copied, and whether a marker row inserted at the subscriber in `m_t1` survives; C5 `sp_droppublication` after its subscriptions are dropped: result, and any 18752 message seen.

- [ ] Step 1: Write the script. Snapshot waits use `wait_until 300` on `MSsnapshot_history` and `MSdistribution_history`.
- [ ] Step 2: Run it. Expected: exit 0, `R|TOTAL|20`.
- [ ] Step 3: Check against what the review panel measured on 2022: C1 leaves 0 rows on every kind; C4 on `nonimm-conc` bulk-copies `m_t3` only and the marker survives. A disagreement is reported.
- [ ] Step 4: Commit.

### Task 6: Subscription, agent and distributor changes (campaign item 5)

Files:
- Create: `lab/campaign/07-changes.sh`, `lab/results/2022/07-changes.txt`

Interfaces:
- Produces: rows `SUB.<property>`, `AGT.<procedure>.<property>`, `PRF.<attempt>`, `SHR.<step>`, `DST.<procedure>.<property>`.

- [ ] Step 1: Write the script, on a publication `m_p` with a push subscription and a shared-agent publication pair `m_s1`, `m_s2` subscribed to `m_sub`:
  - `SUB.*`: one row per property `sp_changesubscription` accepts for a push subscription, listed in the script from the 2019 source `stored-procedures/sp_changesubscription.sql` and checked against the error the procedure returns for an unknown property; each property changed to a non-default value inside a rolled-back transaction with the four flag combinations;
  - `AGT.*`: for `sp_changelogreader_agent`, `sp_changepublication_snapshot` (frequency fields and security) and `sp_changesubscription` agent properties: result and whether the job's schedule or step changed;
  - `PRF.*`: binding the snapshot agent of `m_p` to a new profile `m_prof`: `msdb.dbo.sp_update_agent_profile` executed from `master`, `msdb`, `distribution`, `Sales` (rows `PRF.master`, `PRF.msdb`, `PRF.distribution`, `PRF.Sales`), then a direct `UPDATE` of `MSsnapshot_agents.profile_id` inside a rolled-back transaction (row `PRF.update`), recording the error or the stored `profile_id`;
  - `SHR.*`: drop the subscription of `m_s1` then of `m_s2`, recording after each whether the shared agent row (`publication = N'ALL'`) and its job still exist (rows `SHR.after1`, `SHR.after2`);
  - `DST.*`: `sp_changedistributiondb` for `min_distretention`, `max_distretention`, `history_retention`, and `sp_changedistpublisher` for `working_directory`, `security_mode`, `trusted`, each set to a new value and back, recording result and whether any subscription's status changed.
- [ ] Step 2: Run it. Expected: exit 0; `TOTAL` equals the count, which the script prints; at least 4 `PRF` rows and 2 `SHR` rows.
- [ ] Step 3: Commit.

### Task 7: Pull subscriptions (campaign item 6)

Files:
- Create: `lab/campaign/08-pull.sh`, `lab/results/2022/08-pull.txt`

- [ ] Step 1: Write the script, on publication `m_pp` (`allow_pull = true`) and subscription database `m_psub` on the same instance:
  - `P1.named`: `sp_addsubscription @subscription_type = N'pull'`, then `sp_addpullsubscription @subscription_type = N'pull'` and `sp_addpullsubscription_agent`; record `syssubscriptions.subscription_type`, `MSreplication_subscriptions.subscription_type`, the `MSsubscription_properties` columns, and the job;
  - `P1.omitted`: the same without `@subscription_type` at the subscriber (expected anonymous on 2022);
  - `P2.<property>`: one row per property `sp_change_subscription_properties` accepts, changed and read back;
  - `P3.subscriber-first` and `P3.publisher-first`: the two drop orders (`sp_droppullsubscription` at the subscriber, `sp_dropsubscription` at the publisher), each recording what remains in `syssubscriptions`, `MSreplication_subscriptions`, `MSsubscription_properties` and `msdb.dbo.sysjobs`.
- [ ] Step 2: Run it. Expected: exit 0, `TOTAL` equals the count; `P1.omitted` shows `subscription_type = 2` at the subscriber, as the panel measured; a different value is reported.
- [ ] Step 3: Commit.

### Task 8: Snapshot publications (campaign item 7)

Files:
- Create: `lab/campaign/09-snapshot-pub.sh`, `lab/campaign/09-snapshot-pub-matrix.sql` (the matrix part, run by the `.sh` with `-i`), `lab/results/2022/09-snapshot-pub.txt`

- [ ] Step 1: Write the script: a snapshot publication `m_snap` (`@repl_freq = N'snapshot'`) with tables `m_t1`, `m_t2`, a push subscription, its snapshot delivered, reached with `wait_until`; then the property lists of `02-matrix` that apply to a publication of that kind, same four-cell format, case ids prefixed `SNAP.`.
- [ ] Step 2: Run it. Expected: exit 0, `TOTAL` equals the count.
- [ ] Step 3: Commit.

### Task 9: Initialization modes (campaign item 8)

Files:
- Create: `lab/campaign/10-init-modes.sh`, `lab/results/2022/10-init-modes.txt`

- [ ] Step 1: Write the script, on a publication `m_ip` (`allow_initialize_from_backup = true`, `immediate_sync = 0`) with table `m_t1`:
  - `I1.support-only`: `m_isub1` created by hand with `m_t1` and its data, subscription with `@sync_type = N'replication support only'`;
  - `I2.backup`: backup of the publication database to `/var/opt/mssql/data/m_bak.bak`, restored as `m_isub2`, subscription with `@sync_type = N'initialize with backup'`, `@backupdevicetype = N'disk'`, `@backupdevicename`;
  - `I3.lsn`: subscription `m_isub3` with `@sync_type = N'initialize from lsn'` and the LSN of that backup;
  - for each mode three rows: `.create` (result), `.delivered` (a row inserted at the publisher after creation reaches the subscriber within `wait_until 120`), `.gap` (drop the subscription, insert a row at the publisher, re-add with the same mode, insert another: which of the two rows reach the subscriber).
- [ ] Step 2: Run it. Expected: exit 0, `R|TOTAL|9`; the backup file is removed with the databases.
- [ ] Step 3: Commit.

### Task 10: Defaults and execution contexts (campaign item 9)

Files:
- Create: `lab/campaign/11-defaults.sh`, `lab/campaign/12-contexts.sh`, `lab/distributor-defaults.sh`, their results under `lab/results/2022/`

Interfaces:
- Produces: rows `D.<procedure>.<context>.<column>` with the stored value, and `X.<procedure>.<database>` with the result; Task 12 turns the `D` rows into the defaults table of the spec.

- [ ] Step 1: Write `11-defaults.sh`. For each in-scope procedure, call it with its required parameters only and read back every catalog column it writes, one row per column:
  - `sp_addpublication` in contexts `transactional`, `snapshot`;
  - `sp_addarticle` in contexts `table.native`, `table.concurrent`, `table.character`, `table.snapshot-pub`, `table.non-dbo-schema` (source table `m_s.m_t`, with an unqualified `@ins_cmd = N'CALL m_ins'`), `view-schema-only`, `proc-schema-only`, `func-schema-only`;
  - `sp_addsubscription` push and pull, `sp_addpushsubscription_agent`, `sp_addpullsubscription`, `sp_addpullsubscription_agent`, `sp_addlogreader_agent`, `sp_addpublication_snapshot`;
  - the distributor procedures (`sp_adddistributor`, `sp_adddistributiondb`, `sp_adddistpublisher`) cannot be measured on the configured lab. They go in a separate script, `lab/distributor-defaults.sh VERSION`, run directly and not through `campaign.sh` (it stops the lab, which the restart guard would reject): it shuts `repllab` down, starts a container `m-fresh` (same image, port 11981, `MSSQL_MEMORY_LIMIT_MB=2048`, SQL Agent, no `setup.sql`), runs the three procedures with required parameters only, writes `lab/results/VERSION/distributor-defaults.txt` in the result format, removes `m-fresh` and starts `repllab` again with `lab/start.sh VERSION`.
- [ ] Step 2: Write `12-contexts.sh`: each procedure of Step 1 executed with valid parameters from each of `master`, `msdb`, `distribution`, `Sales` and `m_sub`, recording `ok` or the error number (5001, 14013 and 21482 were seen by the panel), and undoing what succeeded.
- [ ] Step 3: Run `11-defaults.sh` and `12-contexts.sh` through `campaign.sh`, then `lab/distributor-defaults.sh 2022`. Expected: exit 0 for each and a `TOTAL` line in each results file; in `11-defaults`, `D.sp_addarticle.table.native.schema_option` is `0x0000000000030073`, `D.sp_addarticle.table.snapshot-pub.schema_option` is `0x0000000000030071`, `D.sp_addarticle.table.non-dbo-schema.dest_owner` is `m_s`; in `12-contexts`, `X.sp_adddistributor.master` is `14099` on the configured lab (distributor exists) and the other databases give 5001. A different value is reported.
- [ ] Step 4: Commit.

### Task 11: Transient errors and the filter and view rules (campaign items 10, 11)

Files:
- Create: `lab/campaign/13-transient.sh`, `lab/campaign/14-filter-view.sql`, their results

- [ ] Step 1: Write `13-transient.sh`: ten cycles, each creating a publication `m_tr<n>` with one article and a push subscription, waiting for delivery, then dropping the subscription and `sp_droppublication` while the log reader runs; per cycle one row with every error number seen; when an error is seen, the failed statement is run once more and the row records the second result (`retry=ok` or the error). `R|TOTAL|10`.
- [ ] Step 2: Write `14-filter-view.sql`, on publication `m_fv` with table `m_t1 (id, a, b)` and a named view `m_v`, each case in a rolled-back transaction reading `sysarticles.filter_clause`, `OBJECT_ID` of the filter procedure and `OBJECT_DEFINITION` of the view: `F1` `sp_articlefilter` add; `F2` change of clause; `F3` NULL clause; `F4` `sp_articleview` without `@filter_clause` after F1; `F5` `sp_articleview` with the clause after F2; `F6` `sp_articlecolumn` drop after the view exists (does the view lose the column by itself?); `F7` `sp_articlecolumn` add back; `F8` `sp_articlecolumn` before `sp_articleview`. `R|TOTAL|8`.
- [ ] Step 3: Run both. Expected: exit 0; `F2` leaves the view on the old clause and `F4` sets `filter_clause` to NULL, as measured twice by the panel; `F6` answers the question the two review rounds disagreed on.
- [ ] Step 4: Commit.

### Task 12: Fold the results into the documentation

Files:
- Modify: `lab/README.md` (one section per campaign script: what it measures, the results that matter, the rows that surprised)
- Modify: `docs/analysis/step-1-analysis.md` (section 5 and its structural table, sources `[X]` pointing at `lab/results/2022/<script>.txt` case ids)
- Modify: `docs/superpowers/specs/2026-11-10-sqlrepl-plan-apply-design.md` (every "to confirm", the defaults table, the profile binding rule, the shared agent lifecycle, the transient error rule)

- [ ] Step 1: For each "to confirm" and each campaign item of the spec, write the measured answer with its case id, or "not settled" with the reason. Where a result contradicts the spec, change the spec's rule and say in the commit message which rule changed and which row decided it.
- [ ] Step 2: Verify: `grep -n 'to confirm' docs/superpowers/specs/2026-11-10-sqlrepl-plan-apply-design.md` lists only items reported as not settled in Step 1; every `lab/results/2022/*.txt` file is cited at least once in `lab/README.md`.
- [ ] Step 3: Stop the lab (`SHUTDOWN WITH NOWAIT`), report `podman ps`.
- [ ] Step 4: Commit.
