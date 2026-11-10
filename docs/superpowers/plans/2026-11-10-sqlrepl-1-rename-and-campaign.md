# sqlrepl plan 1: rename and measurement campaign

> For agentic workers: REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

Goal: rename `replcfg` to `sqlrepl`, then measure on SQL Server 2022 every replication behavior the planner needs and the spec leaves "to confirm", with scripts that run unchanged on 2019 and 2025.

Architecture: the rename is mechanical Go and docs work. The campaign is a set of self-cleaning measurement scripts under `lab/campaign/`, run by one runner, `lab/campaign.sh`, that guards every run: no leftover object, an unchanged export of the lab's own replication, no instance restart, no uncaught SQL error, and a result count that matches what the script announces. Results are committed as text under `lab/results/2022/`, and the last task folds them into the documentation the planner (plan 3) will be written from.

Tech stack: Go 1.26.5 (existing module, no new dependency), bash, T-SQL through `sqlcmd` in the podman container, SQL Server 2022 Developer.

Spec: `docs/superpowers/specs/2026-11-10-sqlrepl-plan-apply-design.md`, sections "Renaming" and "Measurement campaign". Background: `docs/analysis/step-1-analysis.md` (section 5, the matrix), `lab/README.md` (rows 1 to 12), `CLAUDE.md`.

This is the first of four plans. Plan 2 (model and export extension), plan 3 (planner) and plan 4 (apply) are written after this one has run, from its results: the cost table and several strategies of the spec depend on them.

Revised on 2026-11-10 after a five-reader review (Vibe Mistral and GLM, codex twice, Claude) that ran the plan's statements on the lab.

## Global Constraints

- Everything written in the repository (code, comments, docs, commit messages, results) is in English.
- Documents: no bold, no em dash or en dash, titles that announce their subject without a conclusion or a count.
- Commit messages: prose that says why; no `Co-Authored-By`, `Generated with` or any other attribution trailer.
- No new Go dependency. `gofmt -l .` prints nothing, `go vet ./...` passes.
- The Go module path stays `github.com/rudi-bruchez/sqlserver-replication`.
- The campaign has the lab to itself: `repllab`, `127.0.0.1:11980`, `MSSQL_MEMORY_LIMIT_MB=4096`, one SQL Server container of this project at a time. Nobody else uses `Sales` while a script runs (the export guard would see their changes). The only script that stops the lab is `lab/distributor-defaults.sh` (Task 10), which restarts it itself; it uses 4096 MB too (2048 MB failed with error 701).
- The `sa` password comes from `MSSQL_SA_PASSWORD`, loaded by `set -a; . ~/Sources/Repos/atelier/livres-informatiques/optimiser-sql-server/edition-2026/harnais/.env; set +a`, passed to `sqlcmd` as `SQLCMDPASSWORD`, never with `-P`, never printed.
- `sqlcmd` runs inside the container: a script file is fed on standard input (`sql < file.sql`), never with `-i <host path>` (the container cannot see it: "Invalid filename").
- Every object a campaign script creates is named with the prefix `m_` (tables, publications, databases, profiles, views, procedures, backup files), and the script removes it before it ends, including the jobs, agents and snapshot folders replication created for it. In T-SQL the prefix is matched with `LIKE N'm\_%' ESCAPE N'\'`: an unescaped `_` is a wildcard and matches `master`, `model`, `msdb`.
- Every publication a script creates has its snapshot agent created with a one-time schedule that never fires (`sp_addpublication_snapshot @frequency_type = 1, @active_start_date = 99991231`); snapshots run only when the script starts them (`sp_startpublication_snapshot`). The default schedule (every 5 minutes) regenerates snapshots during a run and moves a publication from one state to another without anyone noticing (review: observed twice).
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

`<case id>` is unique within the script and stable across versions (`S1.O3`, `C2.nonimm-native`). `<result>` is `ok`, an error number, a measured value, or for a flag matrix the cells `f00=…,f10=…,f01=…,f11=…` (`@force_invalidate_snapshot`, `@force_reinit_subscription`; two cells for procedures that only take the first). `<detail>` is free text without `|` or a newline. A T-SQL script builds its rows in a table variable and prints them with one `SELECT` at the end, so that a case that fails still produces its row. Every expected refusal is caught by `TRY…CATCH` and recorded in a row: any `Msg` line that reaches the output is an uncaught error, and the runner rejects it.

## Review Focus

1. A result read before an agent has finished, or after a scheduled run changed the state: scripts disable schedules (Global Constraints), wait on a predicate over agent history with a timeout that fails the run, and record `immediate_sync_ready` in the row of every flag measurement. Pinned by `selftest.sh` fixture `wait-timeout.sh` (Task 2) and the Task 4 state controls.
2. The instance restarting during a run: objects vanish and later cases measure an empty lab without error. The runner compares `tempdb` `create_date` before and after. Pinned by fixture `restart.sh` (Task 2).
3. A script that stops at its first error and reports a short list as if complete, or an uncaught SQL error that `sqlcmd` without `-b` reports with exit 0: the runner fails when the `TOTAL` line is missing or disagrees, and on any line matching `^Msg [0-9]+, Level 1[1-9]` or `^Sqlcmd:`. Pinned by fixtures `total-mismatch.sql` and `uncaught.sql` (Task 2).
4. A connection failure that leaves a results file with zero cases: the runner fails on zero `R|` lines. Pinned by fixture `no-results.sql` (Task 2).
5. A case that leaves an object, a job, an agent row, a snapshot folder or a file behind and changes what the next script measures: the residue guard (Task 2) and the export comparison. Pinned by fixtures `residue.sql` and `residue-job.sh` (Task 2).

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
- [ ] Step 4: Update `CLAUDE.md`, `README.md`, `lab/README.md` and `lab/setup.sql` the same way. In `CLAUDE.md`, the status paragraph names the spec and this plan.
- [ ] Step 5: Verify, in one shell:

```
go build ./cmd/sqlrepl && go vet ./... && test -z "$(gofmt -l .)" && go test ./... && \
left=$(git grep -n -I -e replcfg -e REPLCFG -- . ':!docs/superpowers/') && test -z "$left" && echo RENAME-OK
```

Expected: the last line printed is `RENAME-OK`. `git grep` searches every tracked text file; `docs/superpowers/` keeps the old name where the spec and plans describe the rename. If anything remains, `$left` is printed by rerunning `git grep` and the step is not done.
- [ ] Step 6: Commit.

### Task 2: Campaign runner and its self-test

Files:
- Modify: `lab/start.sh` (version argument, wait for the lab's first snapshots)
- Create: `lab/lib.sh`, `lab/campaign.sh`, `lab/selftest.sh`, `lab/selftest/` (fixture scripts)
- Create: `lab/.gitignore` (`.bin/`)

Interfaces:
- Produces:
  - `lab/start.sh [2019|2022|2025]`: default `2022`; image `mcr.microsoft.com/mssql/server:<version>-latest`; container `repllab`, port 11980, 4096 MB; runs `setup.sql`; then waits (up to 300 s) until `SalesPub` has `immediate_sync_ready = 1` and every `SalesSub` subscription row has `status = 2`, and fails otherwise.
  - `lab/lib.sh`, sourced by shell scripts: `sql [sqlcmd args...]` (runs `sqlcmd` in `repllab` with `-S localhost -U sa -C -W -s '|'`, no `-b`, standard input passed through); `sql_value QUERY` (prints the single value, trimmed); `wait_until TIMEOUT_SECONDS QUERY` (polls every 5 s until `QUERY` returns `1`; at timeout prints `wait_until: timeout after N s: QUERY` on stderr and returns 1).
  - `lab/campaign.sh VERSION SCRIPT...`: builds `lab/.bin/sqlrepl` once; for each script (`.sql` fed to `sql` on standard input, `.sh` executed), writes `lab/results/VERSION/<script basename without extension>.txt` with a first line `# <first line of @@VERSION>` then the script's `R|` lines. On the first failed guard it prints `GUARD <name> failed: <detail>` and exits non-zero.
  - The guards, checked per script, with these names:
    - `results`: at least one `R|` line other than `TOTAL`;
    - `total`: a `TOTAL` line equal to the count;
    - `uncaught`: no output line matching `^Msg [0-9]+, Level 1[1-9]` or `^Sqlcmd:`;
    - `residue`: zero rows for `m_` names (escaped `LIKE`) in `sys.databases`, `Sales.sys.objects`, `SalesSub.sys.objects`, `Sales.dbo.syspublications`, `distribution.dbo.MSpublications.publication`, `distribution.dbo.MSsubscriptions` joined to `MSpublications`, `distribution.dbo.MSsnapshot_agents.publication`, `distribution.dbo.MSdistribution_agents` (`publication` or `subscriber_db`), `msdb.dbo.MSagent_profiles.profile_name`, `msdb.dbo.sysjobs` whose name contains `-m_` (replication job names are `<server>-<database>-<publication>-…`), and zero files under `/var/opt/mssql/data/ReplData/unc` whose folder name contains `_M_` and zero `/var/opt/mssql/data/m_*` files (checked with `podman exec repllab find`);
    - `export`: output of `lab/.bin/sqlrepl export -publisher 'tcp:127.0.0.1,11980' -distributor 'tcp:127.0.0.1,11980' -database Sales -user sa -param encrypt=disable` (password in `SQLREPL_PASSWORD`) identical before and after; on failure the detail says to check that nobody else used `Sales`;
    - `restart`: `tempdb` `create_date` unchanged.

- [ ] Step 1: Write the fixtures in `lab/selftest/`, each a few lines:
  - `good.sql`: prints `R|a|ok|` and `R|TOTAL|1`;
  - `total-mismatch.sql`: two `R|` cases and `R|TOTAL|3`;
  - `no-results.sql`: prints nothing starting with `R|`;
  - `uncaught.sql`: `SELECT m_no_such_column FROM sys.databases;` then `R|a|ok|`, `R|TOTAL|1`;
  - `residue.sql`: creates table `Sales.dbo.m_left`, prints `R|a|ok|`, `R|TOTAL|1`;
  - `residue-job.sh`: creates an empty SQL Agent job named `REPLLAB-Sales-m_ghost-1` with `msdb.dbo.sp_add_job`, prints `R|a|ok|`, `R|TOTAL|1`;
  - `wait-timeout.sh`: sources `lib.sh`, calls `wait_until 10 "SELECT 0"`, prints `R|a|ok|`, `R|TOTAL|1` only if it returned 0;
  - `restart.sh`: `SHUTDOWN WITH NOWAIT`, `podman start repllab`, waits for `SELECT 1`, prints `R|a|ok|`, `R|TOTAL|1`.
- [ ] Step 2: Write `lab/selftest.sh`. It runs `campaign.sh selftest <fixture>` once per fixture and compares the guard each one must trip: `good.sql` exit 0; `total-mismatch.sql` `GUARD total`; `no-results.sql` `GUARD results`; `uncaught.sql` `GUARD uncaught`; `residue.sql` `GUARD residue`; `residue-job.sh` `GUARD residue`; `wait-timeout.sh` `GUARD results`; `restart.sh` `GUARD restart`. A fixture passes only when its exit status and its `GUARD` name are the expected ones. It removes `Sales.dbo.m_left` and the `m_ghost` job right after the fixture that created them, so no fixture sees another's residue, deletes `lab/results/selftest/` at the end, prints `PASS <fixture>` or `FAIL <fixture>: <what happened>` per line and exits non-zero if any line is `FAIL`.
- [ ] Step 3: Run `lab/selftest.sh` before `campaign.sh` exists. Expected: eight `FAIL` lines (command not found is not the expected guard), exit non-zero.
- [ ] Step 4: Write `lab/lib.sh`, `lab/campaign.sh`, the `start.sh` changes and `lab/.gitignore`.
- [ ] Step 5: In one shell: load the password, `lab/start.sh 2022`, `lab/selftest.sh`. Expected: eight `PASS` lines (`good.sql`, `total-mismatch.sql`, `no-results.sql`, `uncaught.sql`, `residue.sql`, `residue-job.sh`, `wait-timeout.sh`, `restart.sh`), exit 0. Any other number of lines means the runner or the self-test is wrong.
- [ ] Step 6: Break one guard on purpose: comment out the `tempdb` comparison in `campaign.sh`, rerun `lab/selftest.sh`. Expected: `FAIL restart.sh` and exit non-zero; seven PASS out of eight is the success of this step. Restore the line, rerun, eight PASS.
- [ ] Step 7: Commit.

### Task 3: Existing measurements under the runner

Files:
- Move and convert: `lab/measure-articles.sql` to `lab/campaign/01-articles.sql`, `lab/measure-matrix.sql` to `lab/campaign/02-matrix.sql`, `lab/measure-add-article.sh` to `lab/campaign/03-add-article.sh`, `lab/measure-filter-clause.sh` to `lab/campaign/04-filter-clause.sh`
- Modify: `lab/README.md` (script names)
- Create: `lab/results/2022/01-articles.txt` … `04-filter-clause.txt`

Interfaces:
- Consumes: `campaign.sh`, `lib.sh` (Task 2).
- Produces: the convention every later script follows, on known measurements.

- [ ] Step 1: Convert each script to the result format. `01-articles` renames its publication `Probe` to `m_probe` and its tables `M1`…`M5` to `m_t1`…`m_t5`, 8 cases (rows 1 to 8). `02-matrix` keeps measuring `SalesPub` and `SalesRef`, which it only touches in rolled-back transactions (allowed by the Global Constraints): 67 cases, one per existing case (38 publication properties, 23 article properties, 6 filter and column operations), cells as today. `03-add-article` builds publications `m_imm` and `m_nonimm` of its own with a subscriber database `m_sub` and measures rows 9, 10, 11 (3 cases). `04-filter-clause` builds `m_fc` and measures row 12 (1 case). The `.sh` scripts replace their fixed `sleep` with `wait_until`.
- [ ] Step 2: Run `lab/campaign.sh 2022 lab/campaign/0[1-4]-*` on a lab started by `lab/start.sh 2022` (which waited for the first snapshots). Expected: exit 0 and `R|TOTAL|8`, `67`, `3`, `1` in the four results files.
- [ ] Step 3: Compare with `lab/README.md` rows 1 to 12 and with the matrix of analysis section 5. Expected: the same results. A difference is reported, not reconciled.
- [ ] Step 4: Commit scripts and results.

### Task 4: Snapshot flag condition (campaign item 1)

Files:
- Create: `lab/campaign/05-snapshot-flag.sh`, `lab/results/2022/05-snapshot-flag.txt`

Interfaces:
- Consumes: `lib.sh`, `campaign.sh`.
- Produces: rows `S<n>.O<m>` and `S<n>.ready` read by Task 12.

Five publication states, each a publication of its own with tables `m_t1 (id, a, b)`, `m_t2`, and a push subscription to its own subscriber database (`m_sub1` … `m_sub5`, so that the five snapshots do not overwrite each other's tables), reached by starting the agents explicitly and waiting on their history:

| State | Publication | `immediate_sync_ready` expected |
|---|---|---|
| S1 | `m_s1`: `immediate_sync = 1`, snapshot generated and delivered | 1 |
| S2 | `m_s2`: `immediate_sync = 1`, subscription added, snapshot agent never started | 0 |
| S3 | `m_s3`: `immediate_sync = 0`, snapshot delivered | 0 |
| S4 | `m_s4`: `immediate_sync = 0`, subscription added, snapshot agent never started | 0 |
| S5 | `m_s5`: `immediate_sync = 1`, snapshot delivered, then invalidated by `sp_changearticle schema_option` with both flags at 1 and not regenerated (its subscription is left waiting for reinitialization, status 1) | 0 |

Nine operations, each in a rolled-back transaction, once per flag combination the procedure accepts (two for `sp_addarticle` and `sp_droparticle`, which only take `@force_invalidate_snapshot`; four for the others): O1 `sp_addarticle` of a new table `m_t3`; O2 `sp_dropsubscription @article = N'm_t2'` (with `@subscriber`, `@destination_db`) then `sp_droparticle N'm_t2'`; O3 `sp_changearticle schema_option` to `0x000000000803509F`; O4 `sp_changearticle description` (control); O5 `sp_changepublication alt_snapshot_folder`; O6 `sp_changepublication sync_method`; O7 `sp_articlefilter` add on `m_t1` (`@filter_name = N'm_f1'`, clause `a > 0`); O8 `sp_articleview` on `m_t1` with that clause (`@view_name = N'm_v1'`); O9 `sp_articlecolumn` drop of `b` on `m_t1`.

- [ ] Step 1: Write the script. One row per state and operation (45 rows); each row's detail carries `ready=<immediate_sync_ready read just before the operation>`. Plus one row `S<n>.ready` per state, read after its nine operations (5 rows). `R|TOTAL|50`.
- [ ] Step 2: Run it through `campaign.sh 2022`. Expected: exit 0 and `R|TOTAL|50`.
- [ ] Step 3: Check the controls. `S1.O3` is `f00=20607,f10=20608,f01=20607,f11=ok` (as `SalesPub` in row 50 of the matrix: only both flags together pass). `S3.O3` passes without the invalidate flag (as `SalesRef`). Every `O4` row is `ok` in all cells. Every row's `ready=` and every `S<n>.ready` equals the expected column of the table above. If a control disagrees, stop and report: a state was not held.
- [ ] Step 4: Commit.

### Task 5: Structural operations (campaign items 2, 3, 4)

Files:
- Create: `lab/campaign/06-structural.sh`, `lab/results/2022/06-structural.txt`

Interfaces:
- Consumes: `lib.sh`; the flag findings of Task 4 decide which flags each case passes, and the row records the flags passed.
- Produces: rows `C<n>.<kind>` read by Task 12.

Four publication kinds, built fresh for each case with tables `m_t1`, `m_t2`, a delivered snapshot and an active push subscription to `m_sub`: `imm-conc` (`immediate_sync = 1`, `sync_method = concurrent`), `imm-native`, `nonimm-conc`, `nonimm-native`.

Cases, each on each kind (5 cases, 20 rows):
- C1: drop the whole subscription with `sp_dropsubscription @article = N'all'`: result, rows left in `syssubscriptions`, distribution agent row and job left.
- C2: drop the subscribed article `m_t2` (`sp_dropsubscription @article = N'm_t2'`, then `sp_droparticle` with the flags Task 4 found): result and flags.
- C3: drop `m_t2` and add it back: which tables the next snapshot bulk-copies (`MSdistribution_history` comments), subscription status of `m_t2`, rows of `m_t2` at the subscriber.
- C4: add `m_t3` and extend the subscription: on `imm-conc` and `imm-native` nothing is called (the subscription is extended at once, lab row 9); on `nonimm-native` `sp_addsubscription @article = N'm_t3'`; on `nonimm-conc` `sp_addsubscription @article = N'all'`. Record the tables bulk-copied, and whether a marker row inserted at the subscriber in `m_t1` before the extension survives.
- C5: `sp_droppublication` after its subscriptions are dropped: result, and any 18752 message seen.

- [ ] Step 1: Write the script. Snapshot and delivery waits use `wait_until 300` on `MSsnapshot_history` and `MSdistribution_history`.
- [ ] Step 2: Run it. Expected: exit 0, `R|TOTAL|20`.
- [ ] Step 3: Check against what the review rounds measured on 2022: C1 leaves 0 rows on every kind; C4 on `nonimm-conc` bulk-copies `m_t3` only and the marker survives. A disagreement is reported.
- [ ] Step 4: Commit.

### Task 6: Subscription, subscriber, agent and distributor changes (campaign item 5)

Files:
- Create: `lab/campaign/07-changes.sh`, `lab/results/2022/07-changes.txt`

Interfaces:
- Produces: rows `SUB.<property>`, `SBR.<property>`, `AGT.<procedure>.<property>`, `PRF.<case>`, `SHR.<step>`, `DST.<procedure>.<property>`.

- [ ] Step 1: Write the script, on a publication `m_p` with a push subscription to `m_sub`, and a shared-agent pair `m_sh1`, `m_sh2` (`independent_agent = 0`) both subscribed to `m_shsub`:
  - `SUB.*`: `sp_changesubscription` takes no force flags (its parameters are `@publication, @article, @subscriber, @destination_db, @property, @value, @publisher`, review). The property list comes from the Learn page of `sp_changesubscription` (fetched with the Microsoft Learn tools); a name the procedure refuses gives 21183, which the row records. One row per property, changed to a non-default value in a rolled-back transaction: result, and whether the subscription's status or its agent's job changed.
  - `SBR.*`: the same for `sp_changesubscriber`, whose parameters are read from `sys.all_parameters`, on the subscriber `@@SERVERNAME`, each change in a rolled-back transaction.
  - `AGT.*`: `sp_changelogreader_agent`, `sp_changepublication_snapshot` (frequency fields and security) and the distribution agent properties of `sp_changesubscription` (`distrib_job_login` and the like, from the same Learn list): result and whether the job's schedule or step changed.
  - `PRF.*`: binding the snapshot agent of `m_p` to a new profile `m_prof` (created with `sp_add_agent_profile`): `PRF.msdb-prefix` runs `EXEC msdb.dbo.sp_update_agent_profile`, which executes in `msdb` whatever the current database (expected 21482); `PRF.distribution-prefix` runs `EXEC distribution.dbo.sp_update_agent_profile` (expected `ok`, verified once during the review); each records the error or the `profile_id` stored in `MSsnapshot_agents`, in a rolled-back transaction.
  - `SHR.*`: drop the subscription of `m_sh1` then of `m_sh2`, recording after each whether the shared agent row (`publication = N'ALL'`, `subscriber_db = N'm_shsub'`) and its job still exist (`SHR.after1`, `SHR.after2`).
  - `DST.*`: `sp_changedistributiondb` for `min_distretention`, `max_distretention`, `history_retention`, and `sp_changedistpublisher` for `working_directory`, `security_mode`, `trusted`, each set to a new value and back: result, and whether any subscription's status changed.
- [ ] Step 2: Run it. Expected: exit 0; `TOTAL` equals the count; `PRF.msdb-prefix` is 21482 and `PRF.distribution-prefix` is `ok` with `m_prof`'s id; 2 `SHR` rows.
- [ ] Step 3: Commit.

### Task 7: Pull subscriptions (campaign item 6)

Files:
- Create: `lab/campaign/08-pull.sh`, `lab/results/2022/08-pull.txt`

- [ ] Step 1: Write the script, on publication `m_pp` (`allow_pull = true`) and subscription databases `m_psub1`, `m_psub2` on the same instance:
  - `P1.named`: `sp_addsubscription @subscription_type = N'pull'` at the publisher, then in `m_psub1` `sp_addpullsubscription @subscription_type = N'pull'` and `sp_addpullsubscription_agent`; record `syssubscriptions.subscription_type`, `MSreplication_subscriptions.subscription_type`, the `MSsubscription_properties` columns, and the job;
  - `P1.omitted`: the same in `m_psub2` without `@subscription_type` at the subscriber (expected anonymous on 2022);
  - `P2.<property>`: one row per property `sp_change_subscription_properties` accepts (list from its Learn page), changed and read back;
  - `P3.subscriber-first` and `P3.publisher-first`: the two drop orders (`sp_droppullsubscription` at the subscriber, `sp_dropsubscription` at the publisher), each recording what remains in `syssubscriptions`, `MSreplication_subscriptions`, `MSsubscription_properties` and `msdb.dbo.sysjobs`.
- [ ] Step 2: Run it. Expected: exit 0, `TOTAL` equals the count; `P1.omitted` shows `subscription_type = 2` at the subscriber, as the review measured; a different value is reported.
- [ ] Step 3: Commit.

### Task 8: Snapshot publications (campaign item 7)

Files:
- Create: `lab/campaign/09-snapshot-pub.sh`, `lab/campaign/09-snapshot-pub-matrix.sql` (fed by the `.sh` to `sql` on standard input), `lab/results/2022/09-snapshot-pub.txt`

- [ ] Step 1: Write the scripts: a snapshot publication `m_snap` (`@repl_freq = N'snapshot'`) with tables `m_t1`, `m_t2`, a push subscription to `m_sub`, its snapshot delivered, reached with `wait_until`; then the property lists of `02-matrix` that `sp_changepublication` and `sp_changearticle` accept for a snapshot publication, same cell format, case ids prefixed `SNAP.`. A property the procedure refuses for this kind of publication is a row with its error, not an omission.
- [ ] Step 2: Run it. Expected: exit 0, `TOTAL` equals the count.
- [ ] Step 3: Commit.

### Task 9: Initialization modes (campaign item 8)

Files:
- Create: `lab/campaign/10-init-modes.sh`, `lab/results/2022/10-init-modes.txt`

- [ ] Step 1: Write the script, on a publication `m_ip` (`allow_initialize_from_backup = true`, `immediate_sync = 0`) in `Sales` with table `m_t1`:
  - `I1.support-only`: `m_isub1` created by the script with `m_t1` and the same rows, subscription with `@sync_type = N'replication support only'`;
  - `I2.backup`: `BACKUP DATABASE Sales TO DISK = N'/var/opt/mssql/data/m_bak.bak' WITH INIT, COPY_ONLY`, restored as `m_isub2` (`WITH MOVE` to `m_isub2` files), subscription with `@sync_type = N'initialize with backup'`, `@backupdevicetype = N'disk'`, `@backupdevicename = N'/var/opt/mssql/data/m_bak.bak'`;
  - `I3.lsn`: `m_isub3` restored from the same backup; subscription with `@sync_type = N'initialize from lsn'` and `@subscriptionlsn` set to that backup's `last_lsn` from `msdb.dbo.backupset`, converted from `numeric(25,0)` to `binary(10)` as three parts: `CAST(lsn / 1000000000000000 AS binary(4)) + CAST((lsn / 100000) % 10000000000 AS binary(4)) + CAST(lsn % 100000 AS binary(2))`;
  - for each mode three rows: `.create` (result), `.delivered` (a row inserted at the publisher after creation reaches the subscriber within `wait_until 120`), `.gap` (drop the subscription, insert a row at the publisher, re-add with the same mode, insert another: which of the two rows reach the subscriber).
- [ ] Step 2: Run it. Expected: exit 0, `R|TOTAL|9`; the backup file is removed with the databases. `COPY_ONLY` keeps the lab's backup chain as it was.
- [ ] Step 3: Commit.

### Task 10: Defaults and execution contexts (campaign item 9)

Files:
- Create: `lab/campaign/11-defaults.sh`, `lab/campaign/12-contexts.sh`, `lab/distributor-defaults.sh`, their results under `lab/results/2022/`

Interfaces:
- Produces: rows `D.<procedure>.<context>.<parameter>` with the stored value or `no-column`, and `X.<procedure>.<database>` with the result; Task 12 turns the `D` rows into the defaults table of the spec.

- [ ] Step 1: Write `11-defaults.sh`. For each in-scope procedure and context below, call the procedure with its required parameters only, then emit one row per optional parameter of the procedure (from `sys.all_parameters`): the value stored in the catalog column that parameter sets, or `no-column` when no catalog column holds it. The script prints, per procedure and context, the number of optional parameters it read from `sys.all_parameters`, and `TOTAL` equals their sum.
  - `sp_addpublication` in contexts `transactional`, `snapshot`;
  - `sp_addarticle` in contexts `table.native`, `table.concurrent`, `table.character`, `table.snapshot-pub`, `table.non-dbo-schema` (source table `m_s.m_t`, with an unqualified `@ins_cmd = N'CALL m_ins'`), `view-schema-only`, `proc-schema-only`, `func-schema-only`;
  - `sp_articlefilter`, `sp_articleview`, `sp_articlecolumn` on a table article;
  - `sp_addsubscription` push and pull, `sp_addpushsubscription_agent`, `sp_addpullsubscription`, `sp_addpullsubscription_agent`, `sp_addlogreader_agent` (on a database `m_pubdb` enabled with `sp_replicationdboption`), `sp_addpublication_snapshot`;
  - `sp_add_agent_profile`, `sp_replicationdboption`.
- [ ] Step 2: Write `12-contexts.sh`: each procedure of Step 1 executed with valid parameters from each of `master`, `msdb`, `distribution`, `Sales` and a database `m_ctx` the script creates, recording `ok` or the error number (5001 and 14013 were seen by the review), and undoing what succeeded. The distributor procedures are not measured here: on a configured lab they return 14099 or 14119 from everywhere.
- [ ] Step 3: Write `lab/distributor-defaults.sh VERSION`, run directly and not through `campaign.sh` (it stops the lab, which the restart guard would reject). It shuts `repllab` down with `SHUTDOWN WITH NOWAIT`, starts a container `m-fresh` (same image, port 11981, `MSSQL_MEMORY_LIMIT_MB=4096`, SQL Agent, no `setup.sql`, the directory `/var/opt/mssql/ReplData` created and owned by `mssql` because `sp_adddistpublisher` defaults to it and refuses a missing one with 21037), then:
  - runs `sp_adddistributor`, `sp_adddistributiondb` and `sp_adddistpublisher` (with `@distribution_db`, which is required) with required parameters only, and emits `D.` rows as in Step 1;
  - before each of them succeeds, runs it once from `msdb`, `tempdb` and `master` and emits `X.` rows (the review saw 5001 outside `master` for `sp_adddistributor`);
  - writes `lab/results/VERSION/distributor-defaults.txt` in the result format, removes `m-fresh` (`podman rm -f`) and starts the lab again with `lab/start.sh VERSION`.
- [ ] Step 4: Run `11-defaults.sh` and `12-contexts.sh` through `campaign.sh`, then `lab/distributor-defaults.sh 2022`. Expected: exit 0 for each and a `TOTAL` line in each results file; in `11-defaults`, `D.sp_addarticle.table.native.@schema_option` is `0x0000000000030073`, `D.sp_addarticle.table.snapshot-pub.@schema_option` is `0x0000000000030071`, `D.sp_addarticle.table.non-dbo-schema.@destination_owner` is `m_s`, and the unqualified `CALL m_ins` is stored as `CALL [dbo].[m_ins]` (review: qualified with `dbo`, not with the source schema); in `distributor-defaults`, `X.sp_adddistributor.msdb` is 5001. A different value is reported.
- [ ] Step 5: Commit.

### Task 11: Transient errors and the filter and view rules (campaign items 10, 11)

Files:
- Create: `lab/campaign/13-transient.sh`, `lab/campaign/14-filter-view.sql`, their results

- [ ] Step 1: Write `13-transient.sh`: ten cycles, each creating a publication `m_tr<n>` with one article and a push subscription to `m_sub`, starting and waiting for delivery, then dropping the subscription with `@article = N'all'` and `sp_droppublication` while the log reader runs; per cycle one row with every error number seen; when an error is seen, the failed statement is run once more and the row records the second result (`retry=ok` or the error). `R|TOTAL|10`.
- [ ] Step 2: Write `14-filter-view.sql`, on publication `m_fv` with table `m_t1 (id, a, b)` and a view named `m_v`. Each case is one rolled-back transaction that builds its own prerequisites from the publication's committed state (no filter, view `m_v` without clause, all columns), then runs the measured call, then reads `sysarticles.filter_clause`, `OBJECT_ID` of the filter procedure and `OBJECT_DEFINITION` of the view:
  - `F1`: `sp_articlefilter @filter_name = N'm_f', @filter_clause = N'a > 0'`;
  - `F2`: F1, then `sp_articlefilter` with clause `a > 1`;
  - `F3`: F1, then `sp_articlefilter` with a NULL clause;
  - `F4`: F1, then `sp_articleview @view_name = N'm_v'` without `@filter_clause`;
  - `F5`: F2, then `sp_articleview @view_name = N'm_v', @filter_clause = N'a > 1'`;
  - `F6`: F1 and `sp_articleview` with the clause, then `sp_articlecolumn` drop of `b` (does the view lose the column by itself?);
  - `F7`: F6, then `sp_articlecolumn` add of `b`;
  - `F8`: `sp_articlecolumn` drop of `b`, then `sp_articleview` with the clause.
  `R|TOTAL|8`.
- [ ] Step 3: Run both. Expected: exit 0; `F2` leaves the view on the old clause and `F4` sets `filter_clause` to NULL, as measured twice by the review; `F6` shows the view without `b` (the last review round saw `sp_articlecolumn` rebuild the view itself).
- [ ] Step 4: Commit.

### Task 12: Fold the results into the documentation

Files:
- Modify: `lab/README.md` (one section per campaign script: what it measures, the results that matter, the rows that surprised)
- Modify: `docs/analysis/step-1-analysis.md` (section 5 and its structural table, sources `[X]` pointing at `lab/results/2022/<script>.txt` case ids)
- Modify: `docs/superpowers/specs/2026-11-10-sqlrepl-plan-apply-design.md` (every "to confirm", the defaults table, the shared agent lifecycle, the transient error rule, the unqualified procedure rule)

- [ ] Step 1: For each "to confirm" and each campaign item of the spec, write the measured answer with its case id, or "not settled" with the reason. Where a result contradicts the spec, change the spec's rule and say in the commit message which rule changed and which row decided it.
- [ ] Step 2: Verify: `grep -n 'to confirm' docs/superpowers/specs/2026-11-10-sqlrepl-plan-apply-design.md` lists only items reported as not settled in Step 1; every `lab/results/2022/*.txt` file is cited at least once in `lab/README.md`.
- [ ] Step 3: Stop the lab (`SHUTDOWN WITH NOWAIT`), report `podman ps`.
- [ ] Step 4: Commit.
