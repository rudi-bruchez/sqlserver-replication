# sqlrepl plan 4: apply Implementation Plan

> For agentic workers: REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

Goal: `sqlrepl apply -f desired.yaml` recomputes the plan against the live servers, asks for `yes`, runs each statement `plan -sql` prints on a pinned connection per server, keeps the snapshot jobs disabled for the length of the run and restores them on every way out, starts the agents the plan lists, and waits for the deliveries the plan owes, with exit codes a script can read.

Architecture: one new impure package, `internal/apply`, beside the pure planner. `plan.Build` stays the only source of what runs: apply executes `Plan.Statements()` as printed, and the facts it needs to wait (which operation owes which delivery, the distribution database, the snapshot roots) are added to the plan by the pure planner (Task 4), so that they are unit-tested without a server and shown by `-json`. `internal/precheck` gains the checks apply relies on (msdb job permission, SQL Server Agent running, the LSN of an `initialize from lsn` subscription), which `plan` and `apply` both consume through `state.Checks`. The CLI only parses flags, wires the connections, prompts and maps the result to an exit code. The convergence harness drops its minimal executor and runs every scenario through `apply`.

Tech Stack: Go 1.26.5 (existing module, no new dependency), T-SQL, the lab container `repllab` (SQL Server 2022 CU27 Developer), bash for the measurement scripts.

Spec: `docs/superpowers/specs/2026-11-10-sqlrepl-plan-apply-design.md`. This plan implements "apply" (steps 1 to 5, the paragraph on failure, 1205 and 18752), "Deliveries owed", the deferral's "generate and wait" step of "Strategies", "Secrets" as far as `apply` needs them (binding, refusal of a missing secret), the msdb permission precondition of "apply" step 3, the LSN check of "Subscriptions", and the central scenario of "Testing". Background: `CLAUDE.md` ("Traps of the planner", "Rulings", "Before step 4"), `docs/analysis/replication-oddities.md` ("Snapshot runs and their history", "Agents and jobs", "Error handling and transactions"), `lab/README.md`. House style and input contract: `docs/superpowers/plans/2026-11-12-sqlrepl-3-planner.md`, "What plan 4 receives".

This is the fourth plan. Plan 5 keeps (R42): "The report" and `sqlrepl snapshot` with `-report` and `-sample-tail`, `apply -rotate-secret`, the windowed test of a generated and undelivered snapshot for `plan` (campaign item 14, first part), campaign items 15 to 18 and the rest of 19 and 20, the named instance, and the 2019 and 2025 replays.

## Global Constraints

- Everything written in the repository (code, comments, docs, commit messages, results) is in English.
- Documents: no bold, no em dash or en dash, titles that announce their subject without a conclusion or a count.
- Commit messages: a subject, a blank line, a prose body that says why; no `Co-Authored-By`, `Claude-Session`, `Generated with` or any other attribution trailer. Stage explicit paths, never `git add -A` or `.`.
- No new Go dependency. `go build ./cmd/sqlrepl`, `go vet ./...`, `test -z "$(gofmt -l .)"` and `go test ./...` without a DSN pass at the end of every task.
- `internal/normalize`, `internal/cost` and `internal/plan` stay pure (`TestPurePackages`). `internal/apply` imports `internal/plan` and `internal/state`, never `internal/reader` or `internal/precheck`: the CLI and the harness wire them.
- The anti-goal 2 rule: the only code path that changes a server is the execution of `plan.Statement.Text`, byte for byte as `plan -sql` prints it. Apply's own statements are reads (`SELECT`, `@@TRANCOUNT`, the job state), the `ROLLBACK` of a transaction a refused call left open, and the application lock. A behavior that needs another write goes into the planner as an operation, never into apply.
- Secret values never appear in any output, log or test failure message, apply's statement log included.
- Only measured behavior is relied on. Where a measurement of Tasks 1 to 3 contradicts this plan or the spec, stop and report what was measured; do not make the code agree with the document.
- Lab tests need `SQLREPL_TEST_DSN` and `SQLREPL_TEST_LAB=1` and run through `lab/gotest.sh` in one shell invocation that loads the password:

  ```
  set -a; . ~/Sources/Repos/atelier/livres-informatiques/optimiser-sql-server/edition-2026/harnais/.env; set +a
  lab/gotest.sh '<anchored filter>' ./internal/convergence
  ```

  The password is passed only by variable name (`SQLCMDPASSWORD`, `MSSQL_SA_PASSWORD`), never printed, never `-P`, never `bash -x`.
- Every test step names its `-run` filter, anchored, and the exact number of `--- PASS` lines, with no `--- SKIP` and no `--- FAIL`. Any other number, larger included, means the filter or the work is wrong.
- Every task has a break step: break the code as it says, run the named test, see it fail, restore. "One failed, the others passed" is the success of that step.
- Lab: container `repllab` on `127.0.0.1:11980`, started by `lab/start.sh 2022` when `podman ps` does not show it. Tests and scripts create only objects named `m_` (databases, tables, publications, profiles, logins, jobs, backup files), remove them in `t.Cleanup` or the script's cleanup even on failure, and touch the lab's own objects (`Sales`, `SalesSub`, `SalesPub`, `SalesRef`, `lab-distrib`) only by reading. `MSreplservers` keeps its five known rows. SQL Server is stopped with `SHUTDOWN WITH NOWAIT`. Task 13 stops and restarts `repllab` and leaves it as it found it; no other container is touched but the `m-agent` container and volume of Task 2 and the `m-fresh` container of Task 13, which their scripts create and remove.
- After each task, append the replication behaviors it measured to `docs/analysis/replication-oddities.md` and to `~/Sources/Repos/atelier/formations/docteur_atomic/sqlserver-replication/research/APPORTS-SQLREPL.md` (memory `course-notes-feed`), in the form those files use.

## Review Focus

1. An interrupt (`Ctrl-C`, `SIGTERM`) during a statement, right after a `job_disable`, at the prompt or during the wait for deliveries: every snapshot job apply disabled is enabled again before the process exits, and the output names any it could not restore. Pinned by `TestLabApplyInterruptRestores` (Task 12), `TestLabRestoreAfterCancel`, `TestLabRestoreReconnects` (Task 7), `TestLabCancelDuringStatement` (Task 6) and `TestRunRefusals` (Task 9).
2. Two `apply` runs on the same publication database at once, or an `apply` while the first waits at its prompt: the second refuses before reading anything; the lock is released on every way out, and never left on a pooled session. Pinned by `TestLabApplyLockRefusesSecond` (Task 12), `TestLabAppLock` and `TestLabUnlockFailureDiscards` (Task 6).
3. A secret whose value holds `'`, `;`, `--` or is empty: bound as a parameter, never spliced; an empty value refuses the run before the prompt. Pinned by `TestLabSecretBinding` (Task 6), `TestLabApplySecret` (Task 12) and `TestApplyRefusesEmptySecret` (Task 9).
4. A snapshot run that someone else started between two operations, or a distribution job that `sp_addpushsubscription_agent` has just started: 22022, 21854 and 21861 are waited out within the bound R52 gives each wait, never reported as a failure of the plan. Pinned by `TestClassify` (Task 6), `TestRetryDecision` (Task 6) and `TestLabApplySnapshotAlreadyRunning` (Task 12).
5. `apply` run again after an `apply` that failed halfway: it plans the remainder, completes it and converges. Pinned by `TestLabApplyResumesAfterFailure` (Task 12).

## Rulings made in this plan

R1 to R41 are plan 3's (`docs/superpowers/plans/2026-11-12-sqlrepl-3-planner.md`); the numbering continues. Each ruling gives its reason and its cost if wrong once, here.

- R42 Scope. Plan 4 builds `apply` and its waits; it writes no snapshot report and adds no `-report` or `-sample-tail` flag (plan 5, with `sqlrepl snapshot`). Spec "The report" says every snapshot `apply` starts produces one: until plan 5, `apply` prints each delivery's outcome instead. Reason: the report is its own subsystem (blocking sampler, file listing, HTML), and apply is complete and testable without it. Cost if wrong: a gap Rudi may not accept, listed as an open question.
- R43 Package. `internal/apply` holds the session (pinned connections), the execution of statements, the error classes, the lock, the job handling, the deliveries owed and `Run`. Every decision that reads no server is a pure function with a unit test (`classify`, `retryDecision`, `effectQuery`, `mask`, `units`, `parseDelivered`, `pubFolder`, `acceptRun`, `exitCode`, `restoreFor`); every server effect has a lab test.
- R44 Order of a run (spec "apply" steps 1 and 2). Apply connects as `plan` does, takes the lock (R45), then reads, prechecks and builds the plan once (`Target.Plan`), prints `Summary()`, and stops before any operation, with exit 1 and nothing run, when the plan is refused, when a precondition is `failed` or `unchecked` among those apply needs (R58), or when a secret is not set (R54). An empty plan prints `Plan for <publisher>.<database>: no changes.`, asks nothing, exits 0. Otherwise it asks, exactly: `Apply <n> operations to <publisher>.<database>, <c> costly (<cost> <k>, ...)? Type yes to apply: `, the parenthesis listing `Totals.ByCost` in `costOrder` without `online` and left out when `<c>` is 0. Only the line `yes` applies; anything else, and `SIGINT` or `SIGTERM` while the question waits (the confirmation races the interrupt channel), prints `Apply cancelled.`, releases the lock and exits 1. `-auto-approve` skips the question; without it and without a terminal on standard input (`os.Stdin.Stat()` has no `os.ModeCharDevice`), apply exits 2 before connecting: "apply needs a terminal to confirm, or -auto-approve". Reason: spec step 2; Terraform's convention for the cancel. Cost: none.
- R45 Application lock. On the publisher's pinned connection, in the publication database, before the read, the batch `DECLARE @rc int; EXEC @rc = sp_getapplock @Resource = N'sqlrepl apply', @LockMode = N'Exclusive', @LockOwner = N'Session', @LockTimeout = 0; SELECT @rc;` (without the `DECLARE` it fails with Msg 137, panel XD); `@rc < 0` refuses, exit 1, `another sqlrepl apply holds the lock on <server>.<database>`. When the file declares `distributor` or `agent_profiles`, the only parts that plan operations on objects shared with other publication databases, apply also takes, before the read, the resource `sqlrepl apply distributor` in `master` on the distributor's pinned connection, with the same batch and refusal (R45a, ruled in Task 13: never in the distribution database, which a plan that creates the distributor has not created yet when the lock is taken, 911; `master` always exists, and one instance has one distributor); a plan with an operation whose path starts with `distributor` or `agent_profiles` while that lock is not held refuses (two applies on different publication databases must not change a shared profile at once). Release: `unlock` issues `USE <the lock's database>` itself, then `sp_releaseapplock` in a batch that returns its `@rc`, and asserts 0: released elsewhere it gives Msg 1223 and -999 (panel C, XD, XN, G). It runs on every way out, after the restores. A failed release is reported (`lock release failed on <server>.<database>: <message>`), never swallowed, and the session is then discarded: `conn.Raw` with a function that returns `driver.ErrBadConn`, which `database/sql` documents as closing the driver connection instead of pooling it (Task 6 checks that this ends the session). `conn.Close()` alone pools the session with the lock held (panel C, M), and the harness's pool lives for the whole test binary. Divergence from the spec, recorded: the spec takes it "before its first operation there"; taking it before the read keeps a second apply from planning against a state the first is changing, and holds it through the prompt. One file is one publication database (spec "Unit and format"). Measured by `TestLabAppLock` (Task 6): the literal batch; a second session is refused; the lock survives a refused call, its `ROLLBACK` and a `USE master` on the holder; after `close`, with the holder's pool still open, a session of another pool takes it (the same pool could hand back the holder's session, where the lock is reentrant). Cost if wrong: a second apply that waits on the prompt of the first, or a later apply refused by a lock nobody holds, which the tests see.
- R45a The distributor lock's database (Task 13). The lock `sqlrepl apply distributor` is taken and released in `master` on the distributor, always, never in the distribution database. Reason: `master` exists before the distributor is configured, while a plan that creates the distribution database failed with 911 at the lock (`lab/fresh-apply.sh`, first run), and one instance has one distributor, so the lock in `master` also serializes two distribution databases of one instance. Cost if wrong: none known; only sqlrepl takes that resource.
- R46 Execution. One `*sql.Conn` per server name compared without regard to case (R7), taken from the first pool `Servers` registers for that name and kept for the whole run; apply's reads at that server use the same connection, in order, from one goroutine. Before a statement, `USE <quoted database>` when the connection's current database differs. The statement runs as `conn.ExecContext(ctx, st.Text, args...)`, `args` one `sql.Named(strings.TrimPrefix(v.Var, "@"), value)` per `st.Secrets` entry (plan 3 ledger, never run through apply before). After every statement, success included, apply reads `@@TRANCOUNT` on that connection; above 0 it runs `IF @@TRANCOUNT > 0 ROLLBACK` and the statement is a failure ("left a transaction open"), even when the driver returned no error (`replication-oddities` "A refused call and its transaction": `@@ERROR` is 0 after some refusals). Exception, spec "Subscriptions": the two statements of a push subscription unit, `sp_addsubscription` then `sp_addpushsubscription_agent` (`units`), run back to back with no read between them, so that the implicit agent never runs before its credentials are set (panel XN measured the gap); `@@TRANCOUNT` is read after the second. A failure of the first is caught by its driver error, which stops before the second, or by the read after the unit. A statement runs under the interrupt context only. The `@@TRANCOUNT` read, its `ROLLBACK`, every restore and the end-of-run reads run under a fresh context bounded by `-timeout`, never under the interrupt context (panel M). Whether a cancelled statement leaves its `*sql.Conn` usable is not relied on (panel C and G disagree; Task 6 records it): when the pinned connection fails one probe (`SELECT @@TRANCOUNT` under that fresh context), apply takes a new connection from the same pool for the restores and the end reads. The lock may have died with that session: the end of the run then prints `lock lost with the connection` instead of releasing it.
- R47 Error classes, `classify(err error) (class, number int)`: `22022` busy job (both wordings, "already running" and "already has a pending request"; the Agent-stopped wording of Task 2, R56, is `agentStopped`); `21854` and `21861` generating; `18752` log reader; `1205` deadlock; any other number or a non-`mssql.Error` other. Per class, after the rollback of R46:
  - `18752` on the measured procedures of `effectQuery` only (`sp_droppublication`, `sp_replicationdboption @value = N'false'`, `sp_changepublication @property = N'sync_method'`, `sp_articlefilter` with the reinit flag): when `@@TRANCOUNT` was 0, apply runs the operation's re-read; done, the step succeeds with the note `18752 tolerated, <what> re-read`; not done, it is a failure. `@@TRANCOUNT` above 0 is a failure. On any other procedure, `sp_droparticle` and `sp_dropsubscription` included (no measurement shows 18752 on them, panel G), 18752 is a failure. Re-reads, each a `SELECT` in the operation's database on its connection: the publication absent from `syspublications`; `syspublications.sync_method` equal to the code of the call's `@value`; `sysarticles.filter_clause` equal to the call's clause (NULL for a NULL `@filter_clause`) and the filter procedure present (absent for NULL); `sys.databases.is_published = 0`. Sources: `CLAUDE.md` "Traps of the planner", ledger lines 93, 213, 229.
  - `21854`, `21861`: wait for the publication's snapshot job to be idle (R48, through `Plan.SnapshotJobLookup(publication)`: `sp_addarticle`, `sp_articlefilter` and `generate_and_wait` have no prologue, and a query on `@job_id` without one fails with Msg 137, panel C), read `immediate_sync_ready`, retry the statement once when `retryDecision(passesInvalidateFlag, ready)` is true (`ready` false, or the call passes `@force_invalidate_snapshot = 1`); a retry that is not allowed, and a second refusal, are failures (spec step 3).
  - `22022`: only on the snapshot starts and the `job_start` statements (R49, R51); on any other statement a failure.
  - `1205` and other: failure, stop (spec "apply", 1205).
- R48 Jobs. After a `job_disable` statement, apply waits until the job is idle: it polls, every second within `-timeout` (R52), `Plan.SnapshotJobLookup(publication)` followed by `SELECT CASE WHEN <plan.JobIdle> THEN 1 ELSE 0 END`, a read built from the planner's parts (`idleQuery`). Each `job_disable` arms its restore, the plan's `job_restore` with the same `Path` (`restoreFor`, R61 for a dropped publication), before the statement is sent, not after it returns (panel XD, XN): a disable that committed while its call returned an error is still restored, and the printed restore sets the value the plan read, harmless if the disable never committed. That value is the file's when the plan changes `job_enabled`, the value found otherwise (R23), on success and failure alike (kept by the panel). On success the restores run in plan order like any statement. On every other way out (a failure, a spent bound, an interrupt), apply runs every armed restore not run yet, in plan order, under a fresh context bounded by `-timeout`, with `@@TRANCOUNT` cleared first, on a connection that passed the probe of R46 or a new one from the same pool; a connection error during a restore makes it reconnect once and retry that restore; what still fails is listed in `Result.JobsLeftDisabled` and printed `job left disabled: <path>`. `SIGINT` and `SIGTERM` are caught for the whole run; a second signal during the restores is ignored. Source: spec step 3.
- R49 Snapshot starts. A `generate_and_wait` statement (`sp_startpublication_snapshot`) that fails with 22022 is retried every second after the job reads idle, within `-wait` (ledger line 204). A `job_start` of a snapshot agent runs its guarded statement, which ends with `SELECT @started AS started` (Task 4): 1 when the guard let `sp_start_job` run and it returned 0, 0 when the guard skipped it. Apply reads that column and compares no clock: `sysjobactivity.run_requested_date` has whole seconds and the lab's server clock is UTC while the host is CET (panel C, M), and every time apply needs, T included, is read from the server. Skipped (a run was in progress, someone else's, `TestLabJobStartGuardPush`), apply waits for that run to end, reads whether the publication is still pending (`pendingQuery`: a `syssubscriptions` row at status 1, or without `immediate_sync` a subscribed article without the active bit, R12) and runs the statement again only then, once per wait, within `-wait`. 22022 from the statement itself (the race R24 names) is the same as a skipped guard. Two starts of one publication are never issued at once (`replication-oddities` "Two snapshot starts at once"). Spec step 5: "writes no report for a run it did not start" holds trivially under R42.
- R50 Deliveries owed. The planner marks them (Task 4): `Operation.Owes` (subscription keys) and `Operation.OwesAt` (`before`, `after` or `marked`), and `Plan.OwedBefore`. Apply records, for each, on the distributor's connection: T (`GETDATE()` read there: `MSdistribution_history.time` is `datetime`, and a `datetime2` T lost a row to rounding, panel XN), the mark (`MAX(timestamp)` of `MSdistribution_history`), the listing of the publication's snapshot folder (folder rule below) and whether its snapshot job runs; `Plan.OwedBefore` right after the plan is read, T at that reading (spec "Deliveries owed"); `before` right before the operation (for a push `subscription` add, before the unit, R46), `after` right after it, `marked` by reading the subscription rows' status (`syssubscriptions`, its own rows, `srvid >= 0`) before and after the call on the publisher's connection and keeping only the subscriptions that went from 2 to 1. A subscription the plan creates gets its status read on the first statement after the unit (pull: after the publisher-side `sp_addsubscription`); status 2 there is the `S7` case. A delivery is confirmed by a `MSdistribution_history` row of the subscription's agent (its `MSdistribution_agents` row by publisher id, publisher database, subscriber through `{servers}`, subscriber database, publication or `N'ALL'`), a row identified by `(agent_id, timestamp)` (the table has no `id` column, panel C, XD, XN, M), with `timestamp` above the mark, `time >= T` and `comments` parsed by `parseDelivered` into `unc\<name>\<run>\`, `<name>` the publication's folder and `<run>` accepted by `acceptRun`: any run of the publication for an `S7` subscription; otherwise a run absent from the listing at T. A run in progress at T is never accepted (the conservative rule, panel C, XN): a record whose snapshot job runs at T is retaken (T, mark, listing) once that job reads idle, before apply starts its own run, so that the in-progress run's folder is listed and refused. Under `concurrent` and `concurrent_c` the subscription's `MSsubscriptions` rows must also read status 2. Folder rule (panel C). The publication's folder name comes from its own path only: under `<root>/unc/`, the directory whose whole name is `<publisher>_<publication database>_<publication>` without regard to case (`pubFolder`; amended in the Task 8 review: the first rule, a name ending with `_<publication database>_<publication>`, took the folder of `x_m_db_m_p` for `m_p`'s and gave a false confirmation; a publisher name with `\`, a named instance, is not identified, its form not measured), never from a "Delivered snapshot" line (a shared agent writes every publication's); none or several: unconfirmed, "snapshot folder of <publication> not identified". `<root>` is `Plan.SnapshotRoots[publication]` and, at T, also `Plan.SnapshotRootsBefore[publication]` when it differs, a run present in either refused (Task 4 review), listed with `sys.dm_os_enumerate_filesystem` at the distributor (0 rows and no error for a folder missing, unreadable or unreachable; recursive; level 1 names without their parent): the columns are those Task 3 row `DL.listing` records, the folder is found by its full path, and the run folders are the directories whose parent path is that folder. For a publication that exists before the plan, a listing at T that does not find its folder makes the delivery unconfirmed, "snapshot folder of <publication> cannot be listed at <path>", and no older run is ever confirmed, except as R50a says. A publication the plan creates has no run before T: its folder absent at T is an empty listing. History is polled every second (the "Delivered snapshot" row is never rewritten in place, `updateable_row` 0 over 75 samples, panel M), every "Delivered snapshot" line seen is kept with its text and time, and confirmation reads what was kept. A pull subscription follows `DL.pull.delivered_line`: `yes`, as push; `no`, unconfirmed with its job state at the subscriber. A shared agent's re-added subscription follows `DL.shared_readd` the same way. Source: spec "Deliveries owed".
- R50a A publication with no run yet (Task 12 fix rounds 1 and 2). For a publication that exists before the plan, when its folder is absent from every root listing at T while every one of those listings shows its root's `unc` directory (a row `<root>/unc` whose parent is `<root>`), the publication has no run yet: its listing at T is empty, and a later run confirms the delivery as for a created publication. Without a `unc` row in every listing that lacks the folder, the delivery is unconfirmed as R50 says. Reason: a folder the server cannot read still appears as a child of its parent, and a missing root lists 0 rows (measured by the controller on repllab with `chmod 000`), so a listed `unc` without the folder is real absence; without the rule, a resume after a failure that came before the first generation ended exit 3 forever. The first version ORed the roots, and the Task 12 review found a false confirmation when the plan changes the root and the old one lists nothing. Cost if wrong: a false confirmation, only if a folder can exist without appearing among its readable parent's children, which the measurement refutes.
- R50b The root of a publication whose plan gives none (Task 13 round 3). When `Plan.SnapshotRoots` has no root for a publication (`working_directory` omitted, instance-dependent, not predicted), apply reads the publisher's `working_directory` from `msdb.dbo.MSdistpublishers` on the distributor when it takes the record, after the distributor exists, the name matched without regard to case (the table stores `REPLLAB` against `@@SERVERNAME` `repllab`); no row, or NULL, keeps "its snapshot root is unknown". Reason: an omitted `working_directory` is the common file, and exit 3 there made the central scenario fail; reading the value from the server is what R49 asks of every value apply needs. Cost if wrong: a root read from a wrong row, guarded by the publisher name match.
- R50c The name of a run (final review, I1). A run is accepted only when its folder name, read as `yyyyMMddHHmmss`, is not earlier than T truncated to the second, and a name that does not parse is not accepted (the `S7` case, which accepts a run listed at T, is exempt); reason: the snapshot agent and T's `GETDATE()` run on the distributor's clock, and the name is the one fact a publication folder unreadable at T, whose listing shows no run, cannot hide; cost if wrong: a clock difference rejects a valid run, which ends unconfirmed.
- R51 Distribution agent starts. The plan's `job_start` statements of distribution and pull agents in step 12 are not run in plan order: each runs when the generation its subscription's owed delivery waits for has ended (at once for `S7`). The end of a generation is the moment the publication's snapshot job reads idle after T, whoever started the run (panel XD, C); a `job_start` with no delivery owed runs after that publication's generation alike. If the job reads idle while the delivery is still owed and `-wait` remains, the same printed statement runs once more, and not again (spec step 5), logged `[<seq>/<n>] again <action> <kind> <path> at <server>, database <database>`; the `-sql` header says that apply may run a `job_start` again when its job ended before its delivery (Task 4), so the text written to the server is still a printed statement (anti-goal 2, panel XD). 22022 means running. The deferral's `job_start` statements of step 9 run in plan order after `generate_and_wait`, once its run has ended; before the first operation after them that is not a `job_start`, apply waits for every delivery the publication owes so far (the subscriptions `generate_and_wait` names, Task 4). Timeout or a failed run there stops apply with `immediate_sync` off, the remaining operations unrun, exit 3 (spec "-defer-full-snapshot" step 3).
- R51a A failed generation (final review, I2). While apply waits for a delivery, a job outcome (`msdb.dbo.sysjobhistory`, `step_id` 0, `run_status` 0) of the publication's snapshot job whose start, read through `msdb.dbo.agent_datetime` and compared on the distributor with T truncated to the second, is not earlier than T ends that delivery at once, unconfirmed, its detail naming the job's last history message (not read for an `S7` record nor for one whose job ran at T); cost if wrong: a failed run followed by a successful retry within the wait ends early, and the user reruns apply.
- R52 Budget and exit codes. `-wait` (default `30m`) starts at the first operation and bounds the waits for generations and deliveries (R49, R51, R50) and the deferral's wait; spent, apply stops at once, restores (R48), and lists what remains and every delivery owed with its state. The idle waits after a `job_disable` and the 21854/21861 retries are part of running the operations and are bounded by `-timeout`, not by `-wait` (panel XD); a spent `-timeout` there is a failure of that operation. `-wait 0` runs every operation and every start, waits for no delivery, and lists every delivery owed as `not awaited`. Exit codes, for both commands:

| Code | `plan` | `apply` |
|---|---|---|
| 0 | printed, no refusal, no failed precondition | nothing to do; or every operation ran and every delivery owed is confirmed |
| 1 | an error or a refusal | an error, a refusal, a failed or unchecked precondition it needs, a secret not set, the lock held, `Apply cancelled.`, a failed statement, a lock release that failed, or operations left unrun (interrupt, a spent bound before the last operation), except the deferral's case of code 3 |
| 2 | a usage error | a usage error, or no terminal without `-auto-approve` |
| 3 | not used | every operation ran and a delivery owed is unconfirmed or not awaited; or, the one exception to code 1 for operations left unrun, the deferral's wait timed out or its run failed (spec "-defer-full-snapshot" step 3, panel XN, M) |
| 4 | printed with a failed precondition and no refusal (minor 9 of the plan 3 final review) | not used |

- R53 What is printed while running, on standard output, each line a template with exact fixed words:
  - `lock taken on <server>.<database>`
  - the summary, the question (R44);
  - per statement, before it runs: `[<seq>/<n>] <action> <kind> <path> at <server>, database <database>`, then the statement text, each line indented two spaces (spec anti-goal 2, "logs each statement before running it"); after it: `  ok (<ms> ms)`, `  18752 tolerated, <what> re-read`, `  retried after <class>`, or `  failed: Msg <number>: <message>`;
  - per wait, when its first read finds something to wait for (so that the line proves a wait happened): `waiting for the snapshot job of <publication> to be idle`, `waiting for the deliveries of <publication>`;
  - per agent start: `started <kind> <publication>[ <subscriber>/<database>]` or `<kind> ... already running`;
  - per delivery owed, at the end: `delivery <publication> to <subscriber>/<database>: confirmed (run <folder>\<run>)`, the folder of R50's rule,, `: unconfirmed (<reason>; job <state>; last history: <comments>)` or `: not awaited`;
  - last: `Applied <ran> of <n> operations; deliveries: <k> confirmed, <u> unconfirmed, <a> not awaited.`, preceded on failure by `Failed at operation <seq>: Msg <number>: <message>` and `Remaining: <seq list>`, and by the `job left disabled` lines and `lock lost with the connection` or `lock release failed ...` (R45, R46).
  Server informational messages are not printed. Server messages can echo a value (Msg 245 echoed a varchar value, panel M): before apply prints any message, `mask` replaces the value of every bound secret with `****`. Errors that end the run before any operation go to standard error with the `sqlrepl:` prefix, as today.
- R54 Secrets. An empty environment variable is not set, for `plan` (`SecretSet`) and `apply` (`Options.Secret`) alike (ledger line 193). `apply` refuses before the prompt while a secret of the plan is not set: `secret <NAME> is not set` per secret, exit 1.
- R55 msdb job permission (spec step 3, R24's `unchecked` precondition). `precheck` reads, at the distributor and at each reached subscriber that runs a pull agent job, `IS_SRVROLEMEMBER(N'sysadmin')`, in `msdb` `IS_ROLEMEMBER(N'SQLAgentOperatorRole')`, and `HAS_PERMS_BY_NAME` for `SELECT` on `msdb.dbo.sysjobs`, `msdb.dbo.sysjobactivity` and `msdb.dbo.syssessions` (`ReadsJobs`, all three). Every printed job operation begins with the prologue, which reads `sysjobs`, and `JobIdle` reads the other two: panel M measured that `SQLAgentOperatorRole` can run `sp_update_job` and `sp_start_job` but fails with 229 on the prologue and on `JobIdle`. The rule therefore keys on Task 1 rows `AP.perm.*.prologue` and `AP.perm.*.activity`, not on the `sp_*` rows: when the operator login read both, the precondition is `ok` for a sysadmin or for an operator whose `ReadsJobs` holds; otherwise, the expected outcome, for a sysadmin only, and the detail names what the operator was refused. Not read (unreachable server): `unchecked`.
- R56 SQL Server Agent running. `precheck` reads, at the same servers as R55, the query Task 2 selects (the first candidate of `AS.detect.*` that reads differently with Agent running and stopped); the precondition `sql server agent` is `ok` or `failed` ("SQL Server Agent is not running: the jobs apply starts would not run"). If no candidate tells them apart, the precondition is `unchecked` with that detail, and apply relies on R47's `agentStopped` class to stop with a clear message. The plan 3 parked item "guard with SQL Agent stopped reads busy" is answered by `AS.guard.stopped`.
- R57 LSN initialization (spec "Subscriptions", `10-init-modes I3`, R21's refusal lifted). A subscription the plan creates with `initialization: lsn` needs `lsn`, written `0x` and 20 hexadecimal digits (`binary(10)`, the form `sp_addsubscription @subscriptionlsn` takes, `10-init-modes.sh` line 199); it is created only when its `state.LSNCheck` is `Valid`: not zero; not beyond the publication database's log end (`sys.dm_db_log_stats(DB_ID(<publication database>)).log_end_lsn` at the publisher, `vlf:block:slot` converted by `lsnFromLogEnd`); and equal to the `last_lsn` of the backup the subscriber database was last restored from, the only value `10-init-modes` I3 measured to work for a creation (`I3.lsn.create`; a value above it skips commands silently, panel C, XD). That backup is read from its `msdb.dbo.restorehistory` row joined to `backupset` at the subscriber, the numeric converted by `lsnFromNumeric` with the exact arithmetic of `10-init-modes.sh` lines 194 to 199 and checked to round-trip), that backup being of the publication database (Task 1 row `AP.lsn.backupset_database` decides whether `server_name` is compared too). No restore history, a subscriber not reached, or a log end not read: `Checked` false, refused, "the LSN of %s cannot be checked: %s". `allow_initialize_from_backup` follows Task 1 row `AP.lsn.no_backup_flag`: refused with that error number, normalization fills it true as a prerequisite (spec "Omitted properties", prerequisites); `ok`, nothing. Reason: a wrong LSN was accepted silently and stopped every subscription of the database (`lab/README.md`, "Initialization without a snapshot"). This is a check against the measured failure, not a proof of correctness (`I3.lsn.gap-original` used the backup LSN after deliveries and failed with 14151); the README says so. The extension of an `lsn` subscription stays refused (R21).
- R58 Preconditions and exit code (minor 9). `plan` exits 4 when it printed a plan with a `failed` precondition and no refusal. `apply` refuses (R44) on any `failed` precondition, and on an `unchecked` `msdb job permission` or `sql server agent` at a server where it runs a job operation. Other `unchecked` preconditions do not refuse: R29 keeps push operations planned for an unreachable subscriber, and dropping the subscription of a subscriber that is gone is a repair apply must allow. Divergence, recorded: spec "Non-goals" has `plan` only warn on a missing snapshot folder; apply refusing it costs a rerun after the folder is made, where running would end in a failed snapshot and exit 3. Kept by the panel fold; open question for Rudi.
- R59 The other parked minors of the plan 3 final review. Minor 7: a warning on an operation that adds a column to an article whose `pre_creation_cmd` is `delete`, `truncate` or `none` ("the subscriber table of %s keeps its columns: the delivery fails with Invalid column name until the column is added there"); a warning on a new article whose destination schema is not `dbo`, whose `schema_option` lacks `create_schemas` (0x8000000), and whose schema a `SchemaCheck` reads absent or unchecked at the subscriber ("schema %s does not exist at %s/%s: the delivery fails"). Minor 11: a change of `destination` that differs only in case keeps its cost and gets the warning "destination %s differs only in case: the subscriber table is dropped and created again". Minor 12: `precheck.Run` takes the current configuration and checks the distributor's current `working_directory` when the file omits it. Minor 13: an operation with a non-empty `Shared` prints ` (shared with <list>)` after its costs in the summary, and a drop of a shared object (cost `shared_object_changed`, action `drop`) counts in `Totals.Costly`.
- R60 Convergence through apply. The harness keeps its environment, files and data checks, and replaces, in the scenarios, `run` followed by `startAndWait` by `e.apply(t, des, opt) *apply.Result`, which calls `apply.Run` with every server of the file mapped to the lab pool, `AutoApprove`, `Wait` 5 minutes, output to `t.Log`; it fails the test unless the outcome is the one the test expects (`applied` with every delivery `confirmed`, by default). The scenarios' plan assertions stay on `e.plan`; the data checks follow the run. `run` and `startAndWait`, with the helpers they call (`startPull`, `startSnapshot`, `dropWith18752`), stay for `jobstart_test.go` alone (panel C): its two guard tests measure the state a plan leaves before any agent start, which apply never leaves, since it starts the agents. `waitDelivered` stays as a data check with a short timeout, since apply has already confirmed the delivery.
- R61 The restore of a dropped publication's job. Today the plan emits a `job_disable` and no `job_restore` for a publication it drops, so a failure before the drop would leave the job disabled. The plan emits, in step 12, a `job_restore` for it with the value found, whose prologue looks the job up without the `THROW` and whose `Guard` is `@job_id IS NOT NULL`: run as printed after the drop, it does nothing; run by R48 on an early way out, it restores. `restoreFor` arms it like any other.
- R62 Planner parts apply reads (panel C, M, XD). `Plan.SnapshotJobLookup(publication)` returns the publication's snapshot job lookup, the prologue the planner writes for its job operations (`jobLookup`), so that every idle wait has a batch that declares `@job_id`. A `job_start` renders `DECLARE @started bit = 0, @rc int;` after its prologue, then `IF <guard>` `BEGIN EXEC @rc = msdb.dbo.sp_start_job @job_id = @job_id; SET @started = CASE WHEN @rc = 0 THEN 1 ELSE 0 END; END;` and last `SELECT @started AS started;`: `-sql` shows it, sqlcmd prints the row harmlessly, and apply reads it (R49). A plan with a `job_start` gets the header line `-- sqlrepl apply may run a job_start again when its job ended before the delivery it owes` (R51). The guard tests of `jobstart_test.go` keep passing: they compose `Call.Prologue` and `Call.Guard`, which do not change.

## Ledger items of plan 3 and where they are folded

| Ledger line (plan 3's ledger, `.superpowers/sdd/2026-11-12-sqlrepl-3-planner/progress.md`, session state) | Folded into |
|---|---|
| 7: plan 4 must check the msdb permission before its first call | R55, Tasks 1, 5 |
| 26: `sp_addsubscription` and `sp_addpublication` start agent jobs implicitly | R49, R51 (guard, 22022 is running) |
| 39: a refused call leaves `@@TRANCOUNT` higher, `@@ERROR` 0; two snapshot starts at once deadlock | R46 (read after every statement), R49 |
| 93, 213, 229: 18752 on `sp_articlefilter` with reinit, `sp_droppublication`, `sp_replicationdboption` false, `sp_changepublication sync_method` | R47 `effectQuery` |
| 153, 216: `sp_start_job` 22022 on a running job; a pull agent started before the generation exits | R51 |
| 161, 169: `Statement.Secrets` binding with `sql.Named` | R46, `TestLabSecretBinding`, `TestLabApplySecret` |
| 165: one batch fails Msg 134 | R46: one statement per batch, as printed |
| 193: an empty secret counts as set | R54 |
| 204: 22022 at snapshot start, retry | R49 |
| 240 to 245, parked: minors 7, 9, 11, 12, 13; `generate_and_wait` names no subscriptions; printed `generate_and_wait` does not wait; guard with Agent stopped | R59, R58, Task 4, R51 (the `waitHeader` already says it; apply waits), R56 |
| Final review line 138 ("tell Rudi", `agent_profiles: []` drops another team's unused profile) | not folded: a spec question for Rudi (spec line 119), unchanged by apply; R59 minor 13 makes such a drop count as costly |

---

### Task 1: Permissions, disabled schedule and LSN bounds

Files:
- Create: `lab/campaign/20-apply.sh`, `lab/results/2022/20-apply.txt`
- Modify: `lab/README.md` (section "Apply preconditions", row in "Planned and measured totals")

Interfaces:
- Produces rows `R|AP.<case>|<result>|<detail>`, read by R55, R57 and by the README.

- [ ] Step 1: Write `lab/campaign/20-apply.sh` on the model of `10-init-modes.sh` (helpers of `lab/lib.sh`, guards, cleanup by trap). Objects: database `m_ap_db` with `dbo.m_t1 (id int PRIMARY KEY, a int)` and 10 rows, published (`sp_replicationdboption`, `sp_addlogreader_agent`); publication `m_ap_p` (transactional, `native`, `independent_agent` true), its snapshot agent on the never-firing schedule, article `m_t1`.
  - Permissions. Logins `m_ap_oper` (msdb user in `SQLAgentOperatorRole`), `m_ap_user` (msdb user in `SQLAgentUserRole`) and `m_ap_none` (msdb user, no role), each with a generated password held in a shell variable, never printed. As each login (`EXECUTE AS LOGIN` in one batch, `REVERT` after), on the snapshot job of `m_ap_p` (owned by the creator, `sa`): `AP.perm.<login>.disable` (`msdb.dbo.sp_update_job @job_id, @enabled = 0`, then back to 1 as `sa`), `AP.perm.<login>.start` (`msdb.dbo.sp_start_job @job_id`; then wait idle as `sa`), `AP.perm.<login>.prologue` (the `SELECT` of `plan`'s job prologue, from `MSsnapshot_agents` joined to `msdb.dbo.sysjobs`), `AP.perm.<login>.activity` (`SELECT` of `msdb.dbo.sysjobactivity` and `syssessions`, the `JobIdle` read). Result `ok` or the error number. Plus `AP.perm.<login>.is_operator` (`IS_ROLEMEMBER(N'SQLAgentOperatorRole')` in msdb, 0 or 1).
  - Disabled schedule (spec item 19). `sp_changepublication_snapshot` of `m_ap_p` to every minute (`@frequency_type = 4, @frequency_interval = 1, @frequency_subday = 4, @frequency_subday_interval = 1`, start today), then at once `sp_update_job @enabled = 0`; wait 150 s; `AP.disabled_schedule` gives `runs=<n>`, the snapshot history runs started after the disable (expected 0); schedule back to never-firing.
  - LSN bounds. A `COPY_ONLY` backup of `m_ap_db` to `/var/opt/mssql/data/m_ap_db.bak`, restored as `m_ap_sub`. `AP.lsn.restorehistory`: the `msdb.dbo.restorehistory` row of destination `m_ap_sub` joined to `backupset` gives a `last_lsn` equal to the backup's (`equal`, `differs`, `none`). `AP.lsn.backupset_database`: that `backupset` row's `database_name` is `m_ap_db` and `server_name` the lab's `@@SERVERNAME` (`db=yes|no server=yes|no`). `AP.lsn.log_end_format`: `log_end_lsn` of `sys.dm_db_log_stats(DB_ID(N'm_ap_db'))` matches `^[0-9A-F]{8}:[0-9A-F]{8}:[0-9A-F]{4}$` (`yes`, `no` with the form). `AP.lsn.no_backup_flag`: a second publication `m_ap_p0` with `allow_initialize_from_backup` false, `sp_addsubscription @sync_type = N'initialize from lsn', @subscriptionlsn = <the backup's last_lsn converted and checked as 10-init-modes.sh does, lines 194 to 207>` to `m_ap_sub`: `ok` or the error number; if `ok`, the subscription is dropped at once. Only a checked LSN is ever passed. Cleanup removes the subscription, publications, the three logins and users, both databases, the backup file and its msdb history as `10-init-modes.sh` does.
- [ ] Step 2: Run, in one shell: load the password, `lab/campaign.sh 2022 lab/campaign/20-apply.sh`. Expected: exit 0, every guard passing, `R|TOTAL|20` (15 permission rows, 1 schedule row, 4 LSN rows). Another count is reported, not reconciled.
- [ ] Step 3: Break step. Make the cleanup skip the drop of `m_ap_oper`. Expected: `GUARD residue failed`. Restore, drop it by hand if left, rerun, the same total.
- [ ] Step 4: README section: what each row decides (R55 from `AP.perm.m_ap_oper.prologue` and `.activity`, expected 229 as panel M measured; R57 from `AP.lsn.*`), and `AP.disabled_schedule` (panel M saw a disabled job start no run at its minute boundary; the row is kept). If `runs` is above 0, stop and report: spec step 3's claim that a disabled job starts no scheduled run is false, and R47's 21854/21861 retry becomes the only guard. Commit.

### Task 2: SQL Server Agent stopped

Files:
- Create: `lab/agent-stopped.sh`, `lab/results/2022/agent-stopped.txt`
- Modify: `lab/README.md`

Interfaces:
- Produces rows `R|AS.<case>|<result>|<detail>`, read by R56 and by `classify` (R47).

- [ ] Step 1: Write the script, run directly like `lab/distributor-defaults.sh`, on a throwaway container, never on `repllab`, whose `MSSQL_AGENT_ENABLED=true` overrides `mssql-conf set sqlagent.enabled false` at every start (panel G measured). The container `m-agent` (same image, `127.0.0.1:11982`, `MSSQL_MEMORY_LIMIT_MB=2048`, volume `m-agent-data`) is first run with `MSSQL_AGENT_ENABLED=true`: a local distributor, database `m_as_db` with `dbo.m_t1` (primary key, 10 rows), publication `m_as_p` with its snapshot agent, and the running reads; then removed and run again on the same volume with `MSSQL_AGENT_ENABLED=false` for the stopped reads. A guard checks the stopped state by another way than the candidates: a plain msdb job `m_as_job` started there has no history row after 30 s. With Agent running, then stopped, read each candidate: `AS.detect.dm_server_services.<state>` (`status_desc` of the `sys.dm_server_services` row whose `servicename` starts with `SQL Server Agent`, or `none`); `AS.detect.agent_sessions.<state>` (count of `sys.dm_exec_sessions` with `program_name LIKE N'SQLAgent - %'`); `AS.detect.xp_servicecontrol.<state>` (`EXEC master.dbo.xp_servicecontrol N'QueryState', N'SQLServerAGENT'`: its output or the error number). With Agent stopped: `AS.guard.stopped` (`plan.JobIdle` evaluated for `m_as_p`'s snapshot job: `idle` or `busy`); `AS.start_job.stopped` (`msdb.dbo.sp_start_job` on that job: error number and the message's first 80 characters); `AS.startpub.stopped` (`sp_startpublication_snapshot @publication = N'm_as_p'` in `m_as_db`: return code, error number and message). The instance is stopped with `SHUTDOWN WITH NOWAIT` before each removal. A trap removes `m-agent` and `m-agent-data` with `podman rm -f` and `podman volume rm`, on success and failure alike; `repllab` is never stopped.
- [ ] Step 2: Run it, in one shell with the password loaded. Expected: exit 0, `R|TOTAL|9`, and afterwards `podman ps -a` and `podman volume ls` show no `m-agent`.
- [ ] Step 3: Break step. Run the stopped state with `MSSQL_AGENT_ENABLED=true` (panel G's trap): `GUARD agent_stopped failed`, the job ran; `m-agent` removed. Restore.
- [ ] Step 4: README section: which candidate R56 uses (or none), the message `classify` reads for `agentStopped`. Commit.

### Task 3: Delivery confirmation sources

Files:
- Create: `lab/campaign/21-deliveries.sh`, `lab/results/2022/21-deliveries.txt`
- Modify: `lab/README.md`

Interfaces:
- Produces rows `R|DL.<case>|<result>|<detail>`, read by R50 and Task 8.

- [ ] Step 1: Write the script. Database `m_dl_db`, tables `m_t1` to `m_t3` (`id int PRIMARY KEY, a int`, 20 rows each); subscriber databases `m_dl_sub1` and `m_dl_sub2`. Cases:
  - `DL.pull.delivered_line`: publication `m_dl_pp` (`allow_pull`, `independent_agent`), a pull subscription to `m_dl_sub1`, snapshot generated, then the pull agent job started at the subscriber; within 120 s: `yes` when `MSdistribution_history` at the distributor has a "Delivered snapshot" row for the pull agent's `MSdistribution_agents` row, `no` otherwise, with `subscriber_rows=<n>` read at the subscriber.
  - `DL.listing`, after `m_dl_pp`'s generation: the columns `sys.dm_os_enumerate_filesystem(<working_directory>/unc, N'*')` returns (`columns=<names>`), the levels it lists (`levels=<list>`), whether a level 1 name holds its parent path (`parent_in_name=yes|no`), and the row count for a missing folder (`missing_rows=<n>`, panel C read 0 with no error). R50's folder rule uses these names.
  - `DL.s7_frequent`: publication `m_dl_ps` (`immediate_sync`, snapshot every minute, delivered); a push subscription added to `m_dl_sub2`, agent continuous: `folder=at_T|after_T` for the folder its "Delivered snapshot" line names against the listing at the call.
  - `DL.shared_readd`: publication `m_dl_pn` (no `independent_agent`), push subscription to `m_dl_sub2` delivered by the shared agent; dropped, re-added with snapshot initialization, generated: `yes` when a new "Delivered snapshot" line of the shared agent above the mark taken before the re-add names `m_dl_pn`'s folder, `no` otherwise.
  Cleanup removes everything, the shared agent included.
  The panel fold dropped `DL.rewrite` (answered: the row is never rewritten, panel M) and `DL.inprogress` (it could not be set up; R50 takes the conservative rule).
- [ ] Step 2: Run, in one shell: `lab/campaign.sh 2022 lab/campaign/21-deliveries.sh`. Expected: exit 0, `R|TOTAL|4`.
- [ ] Step 3: Break step. Skip the drop of `m_dl_sub2`: `GUARD residue failed`. Restore, rerun.
- [ ] Step 4: README section. Write down what each row decides: `DL.pull.delivered_line` the pull branch of R50; `DL.listing` the columns and the filter of R50's folder rule; `DL.s7_frequent` the `S7` branch; `DL.shared_readd` the shared branch. Commit.

### Task 4: Plan additions for apply

Files:
- Modify: `internal/plan/plan.go`, `internal/plan/finish.go`, `internal/plan/lists.go`, `internal/plan/defer.go`, `internal/plan/render.go`, `internal/plan/articles.go`, `internal/plan/build.go`, `cmd/sqlrepl/plan.go`, `internal/convergence/harness_test.go` (`SecretSet`)
- Test: `internal/plan/owes_test.go`, `internal/plan/lists_test.go`, `internal/plan/render_test.go`, `internal/plan/articles_test.go`, `cmd/sqlrepl/plan_test.go`, golden files under `internal/plan/testdata`

Interfaces:
- Produces, in `internal/plan`:

```go
// on Operation
Owes   []string `json:"owes,omitempty"`    // subscription keys (Subscription.Key()) the operation owes a delivery
OwesAt string   `json:"owes_at,omitempty"` // before, after, marked (R50)

// on Plan
OwedBefore     []Owed            `json:"owed_before"`     // pending before the plan
DistributionDB string            `json:"distribution_db"`
SnapshotRoots  map[string]string `json:"snapshot_roots"`  // publication to alt_snapshot_folder, else the distributor's working_directory
SnapshotJobs   map[string]string `json:"snapshot_jobs"`   // publication to its snapshot job lookup (R62)

func (p *Plan) SnapshotJobLookup(publication string) (string, bool)

type Owed struct {
	Publication  string `json:"publication"`
	Subscription string `json:"subscription"`
}

const JobIdle = "..." // renamed from jobIdle, same text
```

- Owes, set in `finish` from the predicted state: a push `subscription` add with `snapshot` initialization, `[key]`, `before`; the publisher-side `sp_addsubscription` of a pull subscription with `snapshot`, `[key]`, `after`; an `article` add on an `immediate_sync` publication, every snapshot-initialized subscription it gives a status 1 row, `after`; a `subscription_extension` of a snapshot-initialized subscription, `[key]`, `after`; an operation costed `reinitialization` (re-adds of R34 aside, which are subscription adds), its `Affects.Subscriptions`, `marked`. `replication_support_only`, `backup` and `lsn` subscriptions are owed nothing. `OwedBefore`: the subscriptions with a row at 1 (or an inactive subscribed article without `immediate_sync`) in the state before the plan. `generate_and_wait`: `Affects.Subscriptions` the subscriptions extended in the deferral's step 2, `Owes` empty.
- R62: `SnapshotJobs` filled by `Build` from `jobLookup` for every publication of the plan; the `job_start` rendering with `@started`, and the `-sql` header line, in `render.go`.
- R61's `job_restore` of a dropped publication; R59's minors 7a, 11, 13; R54 in `cmd/sqlrepl/plan.go` and the harness (`v, ok := os.LookupEnv(name); ok && v != ""`).

- [ ] Step 1: Write the tests. `TestOwesSubscriptionCreation`: a new push subscription with `snapshot` on `SalesRef` has `Owes` its key and `OwesAt` `before` on its `sp_addsubscription`, nothing on its `sp_addpushsubscription_agent`; a pull one has them on the publisher-side call with `after`; a `replication_support_only` one has none. `TestOwesAddArticle`: on ready `SalesPub` the `sp_addarticle` owes every subscription, `after`; on `SalesRef` the `sp_addarticle` owes nothing and the extension owes its subscription. `TestOwesReinitMarked`: a `schema_options` change of `Customer` on `SalesPub` with the reinit flag owes `Affects.Subscriptions`, `marked`. `TestOwedBefore`: a fixture subscription row set to 1 gives one `Owed`; the fixture as is gives none. `TestGenerateAndWaitNamesSubscriptions`: the deferral of `TestDeferSequence` names the extended subscription. `TestPlanDistributionAndRoots`: from the fixture, `DistributionDB` is `distribution` and each publication's root the distributor's working directory, or its `alt_snapshot_folder` when set. `TestSnapshotJobLookup` (R62): each publication of the fixture has a lookup equal to its `job_disable`'s prologue, and an unknown one none. `TestJobStartReportsStarted` (R62): every `job_start` statement holds `DECLARE @started bit = 0, @rc int;`, `EXEC @rc = msdb.dbo.sp_start_job` inside `BEGIN ... END;` under its guard and ends with `SELECT @started AS started;`, and `SQL()` of a plan with a `job_start` holds the R51 header line, of a plan without none. `TestJobRestoreOfDroppedPublication` (R61): a dropped publication gets a step 12 `job_restore` whose prologue has no `THROW`, whose `Guard` is `@job_id IS NOT NULL`, with `@enabled` the value found. `TestColumnAddWarnsPreCreation`: adding a column to an article with `pre_creation_cmd` `delete` warns with the minor 7 text, with `drop` does not. `TestDestinationCaseOnlyWarns`: `t1` to `T1` warns with the minor 11 text and keeps `subscriber_data_replaced`. `TestSummarySharedAndCostly`: a dropped profile with `Shared` `[X.Other]` prints `(shared with X.Other)` and `Totals.Costly` is 1. `TestPlanSecretEmptyNotSet` (`cmd/sqlrepl`): a secret variable set to `""` is listed `not set`.
- [ ] Step 2: Run `go test -count=1 -v -run '^(TestOwesSubscriptionCreation|TestOwesAddArticle|TestOwesReinitMarked|TestOwedBefore|TestGenerateAndWaitNamesSubscriptions|TestPlanDistributionAndRoots|TestSnapshotJobLookup|TestJobStartReportsStarted|TestJobRestoreOfDroppedPublication|TestColumnAddWarnsPreCreation|TestDestinationCaseOnlyWarns|TestSummarySharedAndCostly)$' ./internal/plan` and `go test -count=1 -v -run '^TestPlanSecretEmptyNotSet$' ./cmd/sqlrepl`. Expected: compile failures.
- [ ] Step 3: Implement; regenerate the golden files with `-update` and read their diff: only the new fields, the R61 restore, the R62 `job_start` text and header, and the summary suffixes may change.
- [ ] Step 4: Run the Step 2 commands. Expected: 12 and 1 `--- PASS`. Then, since the `job_start` text changed, `lab/gotest.sh '^TestLabJobStartGuard' ./internal/convergence` (2). Then `go test ./...`.
- [ ] Step 5: Break step. Set `OwesAt` `after` on the push `sp_addsubscription`: `TestOwesSubscriptionCreation` fails. Restore. Keep the `THROW` in R61's prologue: `TestJobRestoreOfDroppedPublication` fails. Restore. Count `shared_object_changed` drops as online: `TestSummarySharedAndCostly` fails. Restore. Set `@started = 1` before the guard: `TestJobStartReportsStarted` fails. Restore.
- [ ] Step 6: Commit.

### Task 5: Preconditions apply needs

Files:
- Create: `internal/precheck/lsn.go`, `internal/precheck/lsn_test.go`
- Modify: `internal/state/facts.go`, `internal/state/facts_test.go`, `internal/precheck/precheck.go`, `internal/precheck/queries.go`, `internal/precheck/precheck_test.go`, `internal/plan/lists.go`, `internal/plan/subscriptions.go`, `internal/plan/call.go`, `internal/normalize/normalize.go` (R57 prerequisite, if `AP.lsn.no_backup_flag` asks for it), `cmd/sqlrepl/plan.go`, `internal/convergence/harness_test.go` (the new `Run` argument)

Interfaces:
- Produces, in `internal/state` (JSON keys in snake case):

```go
// on Checks
JobPermissions []JobPermissionCheck
Agents         []AgentServiceCheck
LSNs           []LSNCheck
Schemas        []SchemaCheck

type JobPermissionCheck struct {
	Server              string
	Checked, Sysadmin   bool
	Operator            bool // SQLAgentOperatorRole in msdb
	ReadsJobs           bool // SELECT on sysjobs, sysjobactivity, syssessions (R55)
}
type AgentServiceCheck struct {
	Server           string
	Checked, Running bool
	Detail           string
}
type LSNCheck struct {
	Publication, Subscriber, Database string
	LSN                               string // as the file writes it
	Checked, Valid                    bool
	Reason                            string // why not valid, or why unchecked
}
type SchemaCheck struct {
	Server, Database, Schema string
	Checked, Exists          bool
}
```

- Produces, in `internal/precheck`:

```go
func Run(ctx context.Context, c Conns, desired, current *model.Config) (*state.Checks, error) // current may be nil (R59 minor 12)

func parseLSN(s string) ([10]byte, error)              // 0x + 20 hex digits
func lsnFromNumeric(s string) ([10]byte, error)        // backupset.last_lsn, round trip checked
func lsnFromLogEnd(s string) ([10]byte, error)         // "xxxxxxxx:xxxxxxxx:xxxx"
func checkLSN(lsn, restored, logEnd [10]byte) (ok bool, reason string) // R57: equal to restored, not beyond logEnd
```

- Plan consumption (`lists.go`): `msdb job permission` and `sql server agent` preconditions per server with job operations, from `Checks` by R55 and R56, `unchecked` when absent; the R57 creation of an `lsn` subscription (`@sync_type = N'initialize from lsn'`, `@subscriptionlsn` the bare `binary(10)` literal, encoder added and the `neverPassed` entry removed) when its `LSNCheck` is `Valid`, the refusal with its `Reason` otherwise; R59 minor 7b's warning from `Schemas`. `r21Lsn` is removed.

- [ ] Step 1: Write the tests. `TestParseLSN`: `0x00000025000001080001` parses; `0x0025`, `00000025000001080001` and `0xZZ...` are errors. `TestLSNFromNumeric`: `37000000026400001` gives `00000025 00000108 0001`; a numeric whose slot exceeds 65535 is an error. `TestLSNFromLogEnd`: `00000025:00000108:0001` gives the same bytes. `TestCheckLSN`: zero refused; above the log end refused; below the restored backup's `last_lsn` refused; above it and below the log end refused (R57); equal to it accepted (`I3.lsn.create`). `TestChecksJSONKeys` gains the four types. `TestBuildLSNSubscription`: a valid check gives `sp_addsubscription` with `@sync_type = N'initialize from lsn', @subscriptionlsn = 0x00000025000001080001`; an invalid one the refusal with its reason; no check the refusal "cannot be checked". `TestBuildJobPreconditions`: sysadmin `ok`; neither role `failed`; operator without `ReadsJobs` `failed`, with it by the R55 outcome; no check `unchecked`; Agent not running `failed` with R56's detail. `TestBuildSchemaMissingWarns`. `TestPrecheckFolderFromCurrent`: a file without a distributor and a current one with a working directory gives a checked folder. `TestPrecheckQueriesParse` gains every new query. `TestLabPrecheckApply` (lab): as `sa`, the lab's server reads `Sysadmin` true and Agent `Running` true; a `SchemaCheck` of `dbo` in `SalesSub` exists, of `m_nos` does not.
- [ ] Step 2: Run `go test -count=1 -v -run '^(TestParseLSN|TestLSNFromNumeric|TestLSNFromLogEnd|TestCheckLSN|TestPrecheckFolderFromCurrent)$' ./internal/precheck`, `go test -count=1 -v -run '^TestChecksJSONKeys$' ./internal/state` and `go test -count=1 -v -run '^(TestBuildLSNSubscription|TestBuildJobPreconditions|TestBuildSchemaMissingWarns)$' ./internal/plan`. Expected: compile failures.
- [ ] Step 3: Implement. The queries are constants of `queries.go`; the lower bound is read at the subscriber's connection, the log end on `Conns.Publisher`.
- [ ] Step 4: Run the Step 2 commands: 5, 1 and 3 `--- PASS`; then `lab/gotest.sh '^(TestPrecheckQueriesParse|TestLabPrecheck|TestLabPrecheckApply)$' ./internal/precheck` (3). Then `go test ./...`.
- [ ] Step 5: Break step. Accept an LSN above the restored backup's `last_lsn`: `TestCheckLSN` fails. Restore. Swap the VLF and block fields in `lsnFromNumeric` (the brief's SQL formula is wrong only in SQL, panel C, so Go integer arithmetic cannot show it): `TestLSNFromNumeric` fails. Restore. Make a missing permission check `ok`: `TestBuildJobPreconditions` fails. Restore.
- [ ] Step 6: Commit.

### Task 6: Session, execution and error classes

Files:
- Create: `internal/apply/session.go`, `internal/apply/classify.go`, `internal/apply/lock.go`, `internal/apply/apply_test.go`, `internal/apply/lab_test.go`

Interfaces:
- Consumes: `plan.Statement`, `plan.Operation`.
- Produces:

```go
// Servers maps a server name of the plan to its pool; lookups ignore case.
type Servers map[string]*sql.DB

type session struct { /* pinned conns, current database per conn */ }
func newSession(s Servers) *session
func (s *session) conn(ctx context.Context, server string) (*sql.Conn, error)
func (s *session) reconnect(ctx context.Context, server string) (*sql.Conn, error)
// healthy probes the pinned conn under a fresh -timeout context and
// replaces it from the same pool when the probe fails (R46).
func (s *session) healthy(ctx context.Context, server string) (conn *sql.Conn, replaced bool, err error)
func (s *session) close() // unlocks (R45), discards a session whose release failed
// exec runs one statement by R46 and returns the driver error, or
// errTranOpen when it succeeded and left a transaction, rolled back.
func (s *session) exec(ctx context.Context, st plan.Statement, secret func(string) (string, bool)) error

type class int // classOther, classBusy, classAgentStopped, classGenerating, classLogReader, classDeadlock
func classify(err error) (class, int)
func retryDecision(passesInvalidateFlag, ready bool) bool
func effectQuery(op plan.Operation) (query string, args []any, ok bool) // R47 re-reads
func secretArgs(st plan.Statement, secret func(string) (string, bool)) ([]any, error)
func mask(message string, values []string) string // R53: every value replaced by ****

const lockBatch = "DECLARE @rc int; EXEC @rc = sp_getapplock ...; SELECT @rc;" // R45, the literal batch
func lock(ctx context.Context, conn *sql.Conn, database, resource string) error // R45; errLocked when held
func unlock(ctx context.Context, conn *sql.Conn, database, resource string) error // USE database, release, rc 0 asserted
func discard(conn *sql.Conn) error // conn.Raw returning driver.ErrBadConn
```

- [ ] Step 1: Write the tests. Unit: `TestClassify`: `mssql.Error` 22022 with each wording is `classBusy`, with the `AS.start_job.stopped` wording `classAgentStopped`, 21854 and 21861 `classGenerating`, 18752 `classLogReader`, 1205 `classDeadlock`, 245 and a non-driver error `classOther`. `TestRetryDecision`: the four cells. `TestEffectQueryCovers`: an operation of each of the four procedures of R47 has a query; `sp_droparticle`, `sp_dropsubscription`, `sp_addarticle`, `sp_articlefilter` without the reinit flag and `sp_changepublication` with `@property = N'retention'` have none. `TestMaskSecrets`: a `Msg 245` message that echoes a secret's value prints it as `****`, every occurrence, and a message without it is unchanged. `TestSecretArgs`: `@secret_1` of `SQLREPL_SQL_X` gives `sql.Named("secret_1", v)`; a secret the function does not return is an error naming `SQLREPL_SQL_X` and not containing the value of any other variable. Lab, on a database `m_ap_exec` the test creates and drops: `TestLabExecRollsBack`: the statement `BEGIN TRAN; RAISERROR(N'm', 16, 1);` returns the error and `@@TRANCOUNT` reads 0 afterwards; `BEGIN TRAN;` alone returns `errTranOpen` and 0 afterwards. `TestLabAppLock` (R45): `lockBatch` runs as written (no Msg 137); a connection of a second pool gets `errLocked`; still after the holder runs a refused `BEGIN TRAN; RAISERROR` and its rollback, and after the holder's `USE master`; `unlock` run while the holder sits in `master` succeeds (it issues the `USE` itself) and the second pool then takes the lock; taken again by the holder, after `close` with the holder's pool still open, the second pool takes it too. `TestLabUnlockFailureDiscards`: `unlock` with a database where the lock was not taken returns the 1223 error; `close` then discards the session, and the second pool takes the lock while the first pool is still open. `TestLabCancelDuringStatement`: `WAITFOR DELAY '00:00:10'` inside `BEGIN TRAN` cancelled after 1 s; the test logs `cancelled conn: usable` or `cancelled conn: bad connection` (the result this task records in `replication-oddities.md`, panel C and G disagreed) and asserts only that `healthy` then gives a connection where `@@TRANCOUNT` reads 0. `TestLabSecretBinding`: a statement `IF @secret_1 <> N'a''b;c--d' THROW 50000, N'm', 1;` with the secret set to `a'b;c--d` succeeds; with another value fails with 50000. `TestLabExecUseOnChange`: three statements in `m_ap_exec` then one in `master` issue two `USE` (counted by a wrapper the test passes).
- [ ] Step 2: Run `go test -count=1 -v -run '^(TestClassify|TestRetryDecision|TestEffectQueryCovers|TestSecretArgs|TestMaskSecrets)$' ./internal/apply`. Expected: compile failure.
- [ ] Step 3: Implement. Check, before relying on it, that `discard` ends the session: `sys.dm_exec_sessions` no longer lists its `@@SPID`. If it does not, stop and report what the driver offers.
- [ ] Step 4: Run the Step 2 command (5 `--- PASS`), then `lab/gotest.sh '^(TestLabExecRollsBack|TestLabAppLock|TestLabUnlockFailureDiscards|TestLabSecretBinding|TestLabExecUseOnChange|TestLabCancelDuringStatement)$' ./internal/apply` (6).
- [ ] Step 5: Break step. Skip the `@@TRANCOUNT` read after a successful statement: `TestLabExecRollsBack` fails on `BEGIN TRAN;`. Restore. Take the lock with `@LockOwner = N'Transaction'`: `TestLabAppLock` fails. Restore. Release without the `USE`: `TestLabAppLock` fails on 1223. Restore. Make `close` call `conn.Close()` without `discard`: `TestLabUnlockFailureDiscards` fails. Restore. Return the message unmasked: `TestMaskSecrets` fails. Restore. Bind the secret under `@secret_1` (prefix kept): `TestLabSecretBinding` fails. Restore.
- [ ] Step 6: Commit.

### Task 7: Jobs and their restore

Files:
- Create: `internal/apply/jobs.go`, `internal/apply/jobs_test.go`
- Modify: `internal/apply/lab_test.go`

Interfaces:
- Consumes: `session` (Task 6), `plan.JobIdle`, `Plan.SnapshotJobLookup` (Task 4, R62).
- Produces:

```go
func restoreFor(p *plan.Plan, disable plan.Operation) (plan.Operation, bool) // R48, R61
type jobs struct { armed []int /* Seq of restores */; ran map[int]bool }
func (j *jobs) arm(p *plan.Plan, disable plan.Operation) // before the disable is sent (R48)
// restoreRemaining runs the armed restores not run yet (R48) and returns
// the paths left disabled.
func (j *jobs) restoreRemaining(s *session, p *plan.Plan, timeout time.Duration, secret func(string) (string, bool)) []string
func idleQuery(lookup string) string // a job lookup + SELECT CASE WHEN JobIdle ...
func waitIdle(ctx context.Context, s *session, server, lookup string, out io.Writer) error // bounded by ctx (-timeout or -wait, R52)
// start runs a printed job_start and reads its started row (R49, R62).
func (s *session) start(ctx context.Context, st plan.Statement) (started bool, err error)
```

- [ ] Step 1: Write the tests. Unit: `TestRestoreFor`: from `TestBuildJobOperations`' plan, each `job_disable` maps to the `job_restore` of the same `Path`; a created publication's step 8 disable maps to its restore; a dropped publication's disable to R61's restore. `TestIdleQuery`: the query is the lookup, a newline, then `SELECT CASE WHEN ` + `plan.JobIdle` + ` THEN 1 ELSE 0 END;`. Lab, with a plain msdb job `m_ap_job` (one T-SQL step `WAITFOR DELAY '00:00:05'`) the test creates and deletes, and hand-written operations whose prologue finds it by name: `TestLabWaitIdle`, every time read on the server (R49): a `job_start`-shaped statement (R62's text) returns `started` 1, a second one while the step runs returns 0; `waitIdle` returns after the step ends, the server's `GETDATE()` read when it returns being at or after the run's `stop_execution_date`, and prints the wait line once; on an idle job it returns at once and prints nothing; `TestLabRestoreAfterCancel`: the job disabled by a `job_disable`-shaped statement, the run's context cancelled, `restoreRemaining` with a fresh timeout enables it (`sysjobs.enabled` 1) and returns nothing; `TestLabRestoreReconnects`: the pinned connection killed (`KILL <spid>` from another connection) before `restoreRemaining`, which reconnects once and enables the job.
- [ ] Step 2: Run `go test -count=1 -v -run '^(TestRestoreFor|TestIdleQuery)$' ./internal/apply`. Expected: compile failure.
- [ ] Step 3: Implement.
- [ ] Step 4: Run the Step 2 command (2 `--- PASS`), then `lab/gotest.sh '^(TestLabWaitIdle|TestLabRestoreAfterCancel|TestLabRestoreReconnects)$' ./internal/apply` (3).
- [ ] Step 5: Break step. Run the restores under the cancelled context: `TestLabRestoreAfterCancel` fails. Restore. Drop the reconnect: `TestLabRestoreReconnects` fails. Restore. Read `started` as true whenever the statement returned no error: `TestLabWaitIdle` fails on the second start. Restore.
- [ ] Step 6: Commit.

### Task 8: Deliveries owed

Files:
- Create: `internal/apply/deliveries.go`, `internal/apply/folders.go`, `internal/apply/queries.go`, `internal/apply/deliveries_test.go`

Interfaces:
- Consumes: `Operation.Owes`, `OwesAt`, `Plan.OwedBefore`, `DistributionDB`, `SnapshotRoots` (Task 4); Task 3's rows.
- Produces:

```go
type owed struct {
	Publication, Subscription string
	T                         time.Time // GETDATE() read at the distributor (R50)
	Mark                      []byte    // rowversion; a history row is (agent_id, timestamp)
	Folder                    string    // the publication's folder, by R50's rule
	Listing                   []string  // run folders at T
	RunningAtT, S7            bool      // RunningAtT: retaken once the job is idle, never confirmed before
	Created, Concurrent       bool      // Created: the plan creates the publication
}
type fsEntry struct { /* the columns Task 3 row DL.listing records */ }
type Delivery struct {
	Publication, Subscription string
	Status                    string // confirmed, unconfirmed, not_awaited
	Run, Detail               string
}
func parseDelivered(comments string) (pubFolder, run string, ok bool)
func acceptRun(o owed, run string) bool
func pubFolder(entries []fsEntry, root, database, publication string) (string, error) // under <root>/unc, by suffix, any case
func runFolders(entries []fsEntry, folderPath string) []string                          // directories whose parent is folderPath
type tracker struct { /* owed records, kept lines */ }
func (t *tracker) record(ctx context.Context, s *session, p *plan.Plan, pub string, subs []string) error // T, mark, folder, listing, running
func (t *tracker) retake(ctx context.Context, s *session, p *plan.Plan, pub string) error               // after a run in progress at T ended (R50)
func (t *tracker) marked(ctx context.Context, s *session, op plan.Operation) (func(context.Context) ([]string, error), error) // statuses before; the returned func reads after, keeps 2 to 1
func (t *tracker) poll(ctx context.Context, s *session, p *plan.Plan) error // one pass: history after the marks, kept lines, MSsubscriptions status for the concurrent family
func (t *tracker) pending(pub string) []owed
func (t *tracker) results(notAwaited bool) []Delivery
```

- Queries in `queries.go`, each a constant with `{dist}` and `{servers}` substituted as the reader's `distQuery` does (`internal/reader/reader.go`): the agent row of a subscription (R50), the history after a mark, the subscription statuses at the publisher, the `MSsubscriptions` statuses, `pendingQuery` (R49), `immediate_sync_ready` (R47), the folder listing.

- [ ] Step 1: Write the tests. `TestParseDelivered`: `Delivered snapshot from the 'unc\REPLLAB_SALES_SALESPUB\20261111162904\' sub-folder in 812 milliseconds` gives `REPLLAB_SALES_SALESPUB` and `20261111162904`; a name with a space is kept (`O19`); any other comment is not ok. `TestAcceptRunFolder`: `S7` accepts a run present at T; a non-`S7` record refuses a run present at T and accepts one absent; a record with `RunningAtT` accepts nothing. `TestPubFolderIdentified`, on entries shaped as `DL.listing` records them: one directory under `<root>/unc` ending `_m_pdb_x_m_p` (any case) names it; two such directories are an error "not identified"; a run folder or a file deeper down with that suffix is ignored; none, for a publication not created by the plan, is the error "snapshot folder of m_p cannot be listed at <path>". `TestRunFolders`: only the directories whose parent is the publication folder, never another publication's runs nor files. `TestQueriesSubstituted`: no query keeps `{dist}` or `{servers}` for `distribution` and `m d]2`. `TestDeliveryResults`: `notAwaited` turns every pending record into `not_awaited`; a confirmed one names `<folder>\<run>`.
- [ ] Step 2: Run `go test -count=1 -v -run '^(TestParseDelivered|TestAcceptRunFolder|TestPubFolderIdentified|TestRunFolders|TestQueriesSubstituted|TestDeliveryResults)$' ./internal/apply`. Expected: compile failure.
- [ ] Step 3: Implement. Add every query of `queries.go` to a `TestApplyQueriesParse` (lab, `SET PARSEONLY ON` on a dedicated `sql.Conn`, as the reader's `TestQueriesParse`).
- [ ] Step 4: Run the Step 2 command (6 `--- PASS`), then `lab/gotest.sh '^TestApplyQueriesParse$' ./internal/apply` (1).
- [ ] Step 5: Break step. Accept a run present at T for a non-`S7` record: `TestAcceptRunFolder` fails. Restore. Compare the folder suffix with case: `TestPubFolderIdentified` fails. Restore. Drop the parent filter: `TestRunFolders` fails. Restore.
- [ ] Step 6: Commit.

### Task 9: The run

Files:
- Create: `internal/apply/run.go`, `internal/apply/result.go`, `internal/apply/run_test.go`

Interfaces:
- Consumes: Tasks 6 to 8.
- Produces:

```go
type Target struct {
	Server, Database string // the publisher and publication database, the lock's place
	Distributor, DistributionDB string // the second lock's place (R45); empty when the file declares neither distributor nor agent_profiles
	Servers          Servers
	Plan             func(ctx context.Context) (*plan.Plan, error) // the read, the prechecks and Build
}
type Options struct {
	Wait, Timeout time.Duration
	AutoApprove   bool
	Confirm       func(question string) (bool, error) // nil with AutoApprove
	Secret        func(name string) (string, bool)     // R54: empty is not set
	Out           io.Writer
	Interrupt     <-chan os.Signal                      // nil: none
	BeforeStatement func(seq int) error                 // a test hook (Task 12): an error stops the run before that statement, as a failure
}
type Outcome string // empty, refused, cancelled, applied, failed, interrupted, unconfirmed
type Failure struct {
	Seq, Number int
	Message     string
}
type Result struct {
	Plan             *plan.Plan
	Outcome          Outcome
	Ran, Remaining   []int
	Failure          *Failure
	Deliveries       []Delivery
	JobsLeftDisabled []string
	LockLost         bool     // R46
	Notes            []string // 18752 tolerated, retries
}
func Run(ctx context.Context, t Target, o Options) (*Result, error) // error: before the lock or the plan
func (r *Result) ExitCode() int
func question(p *plan.Plan) string // R44
func units(p *plan.Plan) [][]int   // Seq groups run back to back: a push subscription's two statements, every other operation alone (R46)
```

- `Run` in order: session; locks (R45); `t.Plan`; `OwedBefore` recorded (R50); print the summary; refusals, preconditions (R58), secrets (R54) and a shared operation without the distributor lock refuse; empty returns; confirm, racing the interrupt (R44); `-wait` from now; for each unit (`units`): owes `before` recorded, `BeforeStatement`, log (R53), a `job_disable` armed before it is sent (R48), execute by its kind (R46 to R49, R51 for the deferral), owes `after` or `marked`, the idle wait after a `job_disable` (R48); the interrupt is read between units; the distribution `job_start` statements of step 12 held for R51; after the last operation, the delivery wait (R50, R51) unless `-wait 0`; on every way out, the probe and restores (R46, R48), then unlock (R45); the last lines (R53), every message through `mask`.

- [ ] Step 1: Write the tests. `TestExitCode`: the R52 table, one case per row of the `apply` column, interrupt after the last operation included (3), interrupt with operations unrun (1), a failed lock release (1), and the deferral's wait timed out with operations unrun (3, the exception). `TestUnits`: a push subscription's `sp_addsubscription` and `sp_addpushsubscription_agent` form one unit, a pull subscription's calls and every other operation one unit each. `TestQuestion`: a plan of 5 operations, 2 costly (`new_snapshot` 1, `reinitialization` 1) gives exactly `Apply 5 operations to REPLLAB.Sales, 2 costly (new_snapshot 1, reinitialization 1)? Type yes to apply: `; with 0 costly, no parenthesis. `TestRunRefusals`, with a `Target` whose `Servers` map to a pool of a fake driver registered by the test (the precheck package's `fake_test.go` pattern) and whose `Plan` returns a given plan: a refused plan gives `refused` and no statement; a `failed` precondition `refused`; an `unchecked` `msdb job permission` `refused`; a secret the function does not return `refused` with `secret SQLREPL_X is not set`; an empty plan `empty`, `Confirm` never called; `Confirm` returning false gives `cancelled` and `Apply cancelled.`; a `SIGINT` on `Interrupt` while `Confirm` blocks gives `cancelled`, `Apply cancelled.` and the release batch sent; a plan with an `agent_profiles` operation and an empty `Target.DistributionDB` `refused`; with it set, the second lock batch is sent before `Plan` is called. `TestApplyRefusesEmptySecret`: `Secret` returning `"", true` is not set.
- [ ] Step 2: Run `go test -count=1 -v -run '^(TestExitCode|TestQuestion|TestRunRefusals|TestApplyRefusesEmptySecret|TestUnits)$' ./internal/apply`. Expected: compile failure.
- [ ] Step 3: Implement.
- [ ] Step 4: Run the Step 2 command. Expected: 5 `--- PASS`.
- [ ] Step 5: Break step. Ask the question before the precondition check: `TestRunRefusals` fails (the fake `Confirm` is called). Restore. Map an interrupt after the last operation to 1: `TestExitCode` fails. Restore. Map the deferral's timeout to 1: `TestExitCode` fails. Restore. Put the push subscription's agent call in a unit of its own: `TestUnits` fails. Restore.
- [ ] Step 6: Commit.

### Task 10: The apply command

Files:
- Create: `cmd/sqlrepl/apply.go`, `cmd/sqlrepl/apply_test.go`
- Modify: `cmd/sqlrepl/plan.go` (the shared wiring), `cmd/sqlrepl/main.go` (the `apply` command, exit codes), `cmd/sqlrepl/plan_test.go`, `README.md` (an `apply` section)

Interfaces:
- Consumes: `apply.Run`, `apply.Target`, `apply.Options`; the plan command's flag parsing and connection code.
- Produces: `func runApply(args []string, stdin io.Reader, stdout, stderr io.Writer) int`, the exit code; `runPlan` returns the R52 code too (4 on a failed precondition). `func prepare(ctx, f *planFlags) (*wiring, error)` and `func (w *wiring) compute(ctx context.Context, opt plan.Options) (*plan.Plan, error)`, the steps of today's `runPlan` from the probe to `Build`, shared by both commands; `wiring` holds the pools, closed by `w.close()`. `var applyRun = apply.Run` and `var isTerminal = func(f *os.File) bool` for the tests. `func confirmer(r io.Reader, w io.Writer) func(string) (bool, error)`: writes the question, reads one line, true only for `yes`.
- Flags: those of `plan` without `-sql` and `-json`, plus `-auto-approve`. `-wait` is R52's budget. Servers: the publisher name to the master pool, the distributor name to its pool, each subscriber to its pool (`Target.Servers`); the publication database's name from the probe; `Target.Distributor` and `DistributionDB` (the file's distributor, else the one the probe reads) when the file declares `distributor` or `agent_profiles` (R45). `Interrupt` from `signal.Notify` on `SIGINT` and `SIGTERM`.

- [ ] Step 1: Write the tests. `TestApplyFlags`: `-f x.yaml -auto-approve -wait 5m` parses; `-sql` is a usage error (exit 2). `TestApplyNoTerminal`: with `isTerminal` false and no `-auto-approve`, exit 2, the message of R44, and `connect` (faked) never called. `TestConfirmer`: `yes\n` true; `y\n`, `YES\n`, `` false; the question is written once. `TestApplyExitCodes`: `applyRun` faked to return each `Outcome`: the exit codes of R52. `TestPlanExitFour`: `buildPlan` faked to return a plan with a `failed` precondition and no refusal: `run` returns 4; with a refusal too, 1. `TestLabApplyCLISalesNoChanges` (lab): `runApply` with `-f ../../internal/testdata/lab/sales.yaml -auto-approve` and `-server` mapping the lab: exit 0, stdout holds `lock taken on` and `no changes.`, and no statement line.
- [ ] Step 2: Run `go test -count=1 -v -run '^(TestApplyFlags|TestApplyNoTerminal|TestConfirmer|TestApplyExitCodes|TestPlanExitFour)$' ./cmd/sqlrepl`. Expected: compile failure.
- [ ] Step 3: Implement. The plan 3 tests of `cmd/sqlrepl` keep passing unchanged except their call of `runPlan`'s return.
- [ ] Step 4: Run the Step 2 command (5 `--- PASS`), then `lab/gotest.sh '^(TestLabApplyCLISalesNoChanges|TestLabPlanCLISalesEmpty|TestLabPlanCLIReadOnly)$' ./cmd/sqlrepl` (3). Then `go build ./cmd/sqlrepl && go vet ./... && test -z "$(gofmt -l .)" && go test ./...`.
- [ ] Step 5: Break step. Check the terminal after connecting: `TestApplyNoTerminal` fails. Restore. Accept `y`: `TestConfirmer` fails. Restore.
- [ ] Step 6: README `apply` section: the order of a run, the question, the lock, the budget, the exit code table, what is printed, and that apply writes no report yet (R42). Commit.

### Task 11: Convergence scenarios through apply

Files:
- Modify: `internal/convergence/harness_test.go`, `internal/convergence/convergence_test.go`, `internal/convergence/strategies_test.go`; `internal/convergence/jobstart_test.go` is read, not changed (R60)

Interfaces:
- Consumes: `apply.Run` (Task 9). Produces `func (e *env) apply(t *testing.T, des *model.Config, opt plan.Options, want apply.Outcome) *apply.Result` (R60) and `func (e *env) target(des *model.Config, opt plan.Options) apply.Target`, whose `Plan` is `e.inputs` then `plan.Build`, and whose distributor lock is set by the R45 rule (`profile.yaml` declares `agent_profiles`).

- [ ] Step 1: Replace every `e.run(t, p)` followed by `e.startAndWait(t, p)` (or alone) by `e.apply(t, des, opt, apply.Applied)` in `convergence_test.go` and `strategies_test.go`; keep `run`, `startAndWait` and their helpers, which only `jobstart_test.go` still calls (R60). A scenario's assertions on the plan stay on `e.plan` before the apply. After each apply, assert that `Result.Deliveries` holds one `confirmed` entry per subscription the scenario expects delivered (a pull subscription by Task 3's `DL.pull.delivered_line`: `confirmed`, or `unconfirmed` with the reason R50 gives), then the existing data checks.
- [ ] Step 2: Run, in one shell, `lab/gotest.sh '^TestLab' ./internal/convergence`. Expected: 18 `--- PASS` (the 7 of `convergence_test.go`, the 9 of `strategies_test.go`, the 2 of `jobstart_test.go`, which still run through `run` and see R62's `job_start` text), and the teardown check of plan 3 Task 19 gives 0. A scenario that fails through apply but passed through the old harness is a defect of apply: find it in apply, never in the scenario's expectations.
- [ ] Step 3: Break step. Make apply run the step 12 distribution `job_start` statements in plan order instead of R51: `TestLabPullSubscription` fails (the pull agent started before the generation exits, the delivery stays unconfirmed). Restore. Make apply skip the delivery wait before the deferral's restore: `TestLabDeferFullSnapshot` fails. Restore.
- [ ] Step 4: Commit.

### Task 12: Apply scenarios on the lab

Files:
- Create: `internal/convergence/apply_test.go`, `internal/convergence/testdata/secret.yaml`, `internal/convergence/testdata/lsn.yaml`, `internal/convergence/testdata/lsn-setup.sql`, `internal/convergence/testdata/running.yaml`, `internal/convergence/testdata/running-add.yaml`
- Modify: `internal/convergence/testdata/teardown.sql` (the login `m_login_<name>`, the backup file and its history)

Interfaces:
- Consumes: the harness of Task 11; `apply.Options.BeforeStatement` (Task 9).
- Scenarios:
  - `TestLabApplySecret`: a SQL login `m_login_<name>` with a password holding `'`, `;` and `--`, mapped to `db_owner` of `{sub}`; `secret.yaml`, a push subscription with `connection.security: sql`, `login: m_login_<name>`, `password_secret: SQLREPL_SQL_M_LOGIN` (the test sets the variable): applied, delivered, converged; no output line holds the password.
  - `TestLabApplyLSN`: `lsn-setup.sql` backs `{db}` up `COPY_ONLY` and restores it over `{sub}`; the test reads the backup's `last_lsn`, converts it in SQL with the arithmetic of `10-init-modes.sh` lines 194 to 199, writes it into `lsn.yaml` (`initialization: lsn`, `lsn: 0x...`), applies: one `sp_addsubscription` with `@sync_type = N'initialize from lsn'`; rows inserted at the publisher after the apply reach `{sub}` (no snapshot), converged.
  - `TestLabApplyLSNRefused`: the same file with an LSN one above the log end, and a `BeforeStatement` hook that fails the test and returns an error at the first statement, so that a wrong LSN can never reach the lab (`lab/README.md`, "Initialization without a snapshot"): `refused`, `Result.Ran` empty, no subscription exists afterwards.
  - `TestLabApplyLockRefusesSecond`: a first apply of `create.yaml` held at its `Confirm` (the fake blocks on a channel); a second apply of the same file returns `refused` with the lock message; the first is then released and applies; after it returns, with the harness pool still open, a connection of a second pool the test opens takes `sqlrepl apply` in `{db}` (R45: the same pool could hand back the holder's session).
  - `TestLabApplyWaitZero`: `create.yaml` with `Wait` 0: every operation ran, `unconfirmed` outcome, exit code 3, the subscription's delivery `not_awaited`; a later apply of the same file after the delivery plans nothing.
  - `TestLabApplyResumesAfterFailure`: `create.yaml` with `BeforeStatement` returning an error before the `sp_addsubscription`: outcome `failed`, exit 1, the snapshot job of `m_p` enabled afterwards (R48), `Remaining` lists the rest; a second apply without the hook applies the remainder, delivered, converged.
  - `TestLabApplyInterruptRestores`: `create.yaml`, applied; `add-article.yaml` applied with a `BeforeStatement` hook on the statement after the first `job_disable`: it reads `sysjobs.enabled` 0 for that job (the disable committed and the job is still disabled, else the test fails), feeds `Interrupt` a `SIGINT` and returns nil; outcome `interrupted`, exit 1, `Remaining` not empty, every snapshot job of `{db}` enabled afterwards, no `job left disabled` line.
  - `TestLabApplySnapshotAlreadyRunning`: `running.yaml` (`create.yaml` with `immediate_sync: true` and an article `m_big` of 2 000 000 rows the test inserts first, so that a generation lasts), applied; the test starts `m_p`'s snapshot (`sp_startpublication_snapshot`), waits until `plan.JobIdle` reads busy, then applies `running-add.yaml` (one article more): applied; the output holds `waiting for the snapshot job of m_p to be idle`, printed only when the first read finds the job busy (R53), so the wait happened; the delivery confirmed names a run whose folder name, a server timestamp, is later than the `stop_execution_date` of the run the test started (R50: a run in progress at T is not accepted); converged.
  - `TestLabApplyOwedBefore` (R50, panel G, C): `create.yaml` applied; the test stops the distribution agent's job and marks the subscription for reinitialization (`sp_reinitsubscription`), so that it is pending before the plan; an apply of `create.yaml` has the subscription in `Plan.OwedBefore`, starts the agents, and confirms its delivery; converged.

- [ ] Step 1: Write the files and the nine tests.
- [ ] Step 2: Run, in one shell, `lab/gotest.sh '^TestLabApply' ./internal/convergence`. Expected: 9 `--- PASS`, the teardown check 0, and no `m_login_` login left.
- [ ] Step 3: Break step. Restore only on success: `TestLabApplyResumesAfterFailure` and `TestLabApplyInterruptRestores` fail on the job's enabled state. Restore. Skip the record of `OwedBefore`: `TestLabApplyOwedBefore` fails (no delivery confirmed). Restore. Accept a run in progress at T: `TestLabApplySnapshotAlreadyRunning` fails on the confirmed run. Restore. Treat every `LSNCheck` as valid: `TestLabApplyLSNRefused` fails in its hook, before any statement reaches the server. Restore.
- [ ] Step 4: Commit.

### Task 13: Central scenario from an instance without replication

Files:
- Create: `lab/fresh-apply.sh`, `lab/fresh/create.yaml`, `lab/fresh/setup.sql`, `lab/results/2022/fresh-apply.txt`
- Modify: `lab/README.md`

Interfaces:
- Consumes: the `sqlrepl` binary built by the script; R17 (local distributor creation), plan 3's distributor strategy.

- [ ] Step 1: Write the script on the model of `lab/distributor-defaults.sh`: shut `repllab` down, start `m-fresh` (same image, `127.0.0.1:11981`, `MSSQL_MEMORY_LIMIT_MB=4096`, Agent on, `/var/opt/mssql/ReplData` created and owned by `mssql`), run `setup.sql` (database `m_fresh_pub` with `dbo.m_t1` of 20 rows and a primary key, empty `m_fresh_sub`), then `sqlrepl apply -f lab/fresh/create.yaml -server <its @@SERVERNAME>=tcp:127.0.0.1,11981 -user sa -param encrypt=disable -auto-approve -wait 10m`, the password through `SQLREPL_PASSWORD`. `create.yaml` declares the distributor (local, `distribution`, `working_directory: /var/opt/mssql/ReplData`, its `admin_password_secret` set from a generated value), one publication `m_p` (`native`, `independent_agent`, `status: active`) with `m_t1`, one push subscription to `m_fresh_sub`. Rows: `FA.apply` (exit code, expected 0), `FA.delivered` (row count of `m_fresh_sub.dbo.m_t1`, expected 20), `FA.export_plan` (`sqlrepl export` then `sqlrepl plan` of the export: `no changes`), `FA.file_plan` (`sqlrepl plan` of `create.yaml`: `no changes`). A trap removes `m-fresh` with `podman rm -f` and starts the lab with `lab/start.sh 2022`, on success and failure alike.
- [ ] Step 2: Run it, in one shell with the password loaded. Expected: exit 0, `R|TOTAL|4`, every row as expected; `podman ps` shows `repllab` and no `m-fresh`; `lab/gotest.sh '^TestLabSalesPlanEmpty$' ./internal/convergence` gives 1 `--- PASS`.
- [ ] Step 3: Break step. Remove `working_directory` from `create.yaml`: the apply fails (21037, or the refusal R17's code gives) and the script exits 1 with `m-fresh` removed and `repllab` back. Restore.
- [ ] Step 4: README section (the central scenario of spec "Testing"). Commit.

### Task 14: Documentation and the whole suite

Files:
- Modify: `README.md`, `CLAUDE.md`, `lab/README.md`, `docs/analysis/replication-oddities.md`

- [ ] Step 1: `CLAUDE.md`: status (plan 4 done; `apply` exists; what plan 5 keeps, R42); architecture (`internal/apply`, the new `Checks`, the plan fields of Task 4); the traps found while building, each with its row or test; the rulings later sessions must not undo without a measurement (R45 to R52, R55 to R58, R61, R62); replace "Before step 4" by "Before plan 5". `README.md`: `apply` complete. `lab/README.md`: the scripts of Tasks 1 to 3 and 13, and how the convergence tests now run through `apply`.
- [ ] Step 2: Run the whole suite on the lab, in one shell: `lab/gotest.sh '.' -timeout 60m ./...`. Expected: no `--- FAIL`, no `--- SKIP`; report the count. Then `go build ./cmd/sqlrepl && go vet ./... && test -z "$(gofmt -l .)" && go test ./...`. Check that nothing is left: no `m_` database, job, login, publication or profile, `MSreplservers` with its five rows.
- [ ] Step 3: Break step. Run `SQLREPL_TEST_LAB=1 go test -count=1 -v -run '^TestLabAppLock$' ./internal/apply` without the DSN: it fails, it does not skip.
- [ ] Step 4: Stop the lab (`SHUTDOWN WITH NOWAIT` through `sqlcmd`), report `podman ps`. Commit.

## What plan 5 receives

- `apply.Run` with its `Result`, the deliveries it confirms (`Delivery`), and its waits, which `sqlrepl snapshot` reuses for one publication; the R53 output lines, which the report extends rather than replaces.
- `Operation.Owes`, `OwesAt`, `Plan.OwedBefore`, `DistributionDB`, `SnapshotRoots`; the queries of `internal/apply/queries.go`.
- The rows of `20-apply`, `agent-stopped`, `21-deliveries` and `fresh-apply`.
- Open: the report and `-sample-tail` (R42), `-rotate-secret`, the windowed test of a generated and undelivered snapshot for `plan`, campaign items 15 to 18, the named instance, the remote distributor (R17), the 2019 and 2025 replays (R18), and the spec's line 119 on dropping another database's unused profile.

## Panel of d7fd2a0, folded

Five readers (Claude neutral, codex directive and neutral, GLM neutral, Mistral directive); the controller's rulings, by number, and where each went.

- 1 (R45, Task 6 `lockBatch`, `TestLabAppLock`); 2 (R45, Task 6 `unlock`, `TestLabAppLock`, break step); 3 (R45, R53, Task 6 `discard`, `TestLabUnlockFailureDiscards`, Step 3 check; Task 12 `TestLabApplyLockRefusesSecond`); 4 (R45, Task 9 `Target`, `TestRunRefusals`, Tasks 10 and 11); 5 (R46, R48, R53, Task 6 `healthy`, `TestLabCancelDuringStatement`; Task 9 order); 6 (R48, Task 7 `arm`, Task 9 order); 7 (Task 12 `TestLabApplyInterruptRestores`, Outcome `interrupted`, Step 3); 8 (R44, Task 9 `TestRunRefusals`); 9 (R46, Task 9 `units`, `TestUnits`); 10 (R47, Task 6 `TestEffectQueryCovers`); 11 (R53, Task 6 `mask`, `TestMaskSecrets`); 12 (R47, R48, R62, Task 4 `TestSnapshotJobLookup`, Task 7 `idleQuery`); 13 (R49, R62, Task 4 `TestJobStartReportsStarted`, Task 7 `session.start`); 14 (R51); 15 (R50, Task 3, Task 8 `retake`, `TestAcceptRunFolder`, Task 12 `TestLabApplySnapshotAlreadyRunning`); 16 (R50, Task 3, Task 8 `owed`); 17 (R50, Task 8 `owed`); 18 (R50, Task 3 `DL.listing`, with one adaptation: a publication the plan creates has no folder at T, so its absence there is an empty listing; Task 8 `pubFolder`, `runFolders`, `TestRunFolders`); 19 (R50, R53, Task 8 `TestPubFolderIdentified`, `TestDeliveryResults`); 20 (R50, Task 9 order, Task 12 `TestLabApplyOwedBefore`); 21 (R51, R62, Task 4 `TestJobStartReportsStarted`); 22 (R48, R52, Review Focus 4, Task 7 `waitIdle`); 23 (R52 table, Task 9 `TestExitCode`); 24 (R55, Task 1 Step 4, Task 5 `ReadsJobs`, `TestBuildJobPreconditions`); 25 (Global Constraints, Task 2); 26 (R57, Task 5 `checkLSN`, `TestCheckLSN`, break step); 27 (R58); 28 (R60, Task 11 Files, Steps 1 and 2, 18 kept); 29 (Task 5 Step 5); 30 (Task 7 `TestLabWaitIdle`).
- Kept as written: R42, R45's lock before the read, the 18752 re-read, R61, the restore value (R42, R45, R47, R61 unchanged; the restore value written in R48). Done by the plan's measurements: disabled schedule, LSN arithmetic, `log_end_lsn` format (Task 1 rows kept, Step 4 cites panel M).

## Self-review

- Spec coverage. "apply" step 1 (R44, Task 9 `Target.Plan`), step 2 (R44, Tasks 9 and 10), step 3 (R46 pinned connections, R48 disable, idle wait and restore on every way out, R45 lock, R55 permission, R52 budget), step 4 (R46, R47), step 5 (R49, R50, R51, R52), the failure paragraph (R52, R53, Task 12 `TestLabApplyResumesAfterFailure`), 1205 and 18752 (R47). "Deliveries owed" (R50, Tasks 3, 4, 8). The deferral's generate and wait (R51, Task 4, Task 11 `TestLabDeferFullSnapshot`). "Secrets" for apply (R46, R54, Tasks 6 and 12). "Subscriptions", the LSN check (R57, Tasks 1, 5, 12). "Testing", the central scenario (Task 13) and the scenarios through apply (Task 11). "The report" and `-rotate-secret`: plan 5 (R42).
- Unmeasured inputs found while writing, each given a measurement before its consumer: the msdb roles and the disabled schedule and the LSN bounds (Task 1, consumed by Tasks 5 and 12), Agent stopped (Task 2, Tasks 5 and 6), the pull line, the listing's columns, the `S7` folder and the shared re-add (Task 3, Task 8); the in-place rewrite was answered by the panel, and the run in progress takes the conservative rule instead of a measurement. A cancelled statement's connection is recorded by Task 6 and relied on in neither form. The application lock's behavior is tested directly (Task 6), since no outcome would change R45 but its failure.
- Type consistency: `plan.Statement`, `StatementSecret` (plan 3) used by `session.exec` and `secretArgs`; `plan.JobIdle` exported in Task 4, used by Tasks 2 and 7; `Plan.SnapshotJobLookup` and R62's `job_start` text produced by Task 4, consumed by Task 7 (`idleQuery`, `session.start`) and Task 9 (R47's waits); `Operation.Owes`, `OwesAt`, `Plan.OwedBefore`, `DistributionDB`, `SnapshotRoots` produced by Task 4 and consumed by Task 8 (`OwedBefore` recorded by Task 9's `Run`); `state.JobPermissionCheck.ReadsJobs` produced by Task 5, read by R55's rule in `lists.go`; `lock`, `unlock`, `discard`, `mask` and `session.healthy` produced by Task 6, used by Task 9; `Target.Distributor` and `DistributionDB` set by Tasks 10 and 11; `state.JobPermissionCheck`, `AgentServiceCheck`, `LSNCheck`, `SchemaCheck` produced by Task 5 and consumed by `plan` in Task 5 and by `Run`'s refusals in Task 9 through `Plan.Preconditions`; `precheck.Run`'s new `current` argument updated in the CLI and the harness in Task 5; `apply.Servers`, `Target`, `Options`, `Result`, `Outcome`, `Delivery` produced by Tasks 6, 8 and 9 and consumed by Tasks 10 to 12.
- Test counts per task, after the panel fold: Task 1 `TOTAL|20`; Task 2 `TOTAL|9`; Task 3 `TOTAL|4`; Task 4: 12 and 1, then 2 lab; Task 5: 5, 1 and 3, then 3 lab; Task 6: 5, then 6 lab; Task 7: 2, then 3 lab; Task 8: 6, then 1 lab; Task 9: 5; Task 10: 5, then 3 lab; Task 11: 18 lab; Task 12: 9 lab; Task 13 `TOTAL|4` and 1 lab.
- Proportion: signatures, rulings with their sources, test names and assertions; no function body. The only exact text is the question, the output templates, the lock batch, R62's `job_start` text and the exit code table, which the tests pin.
