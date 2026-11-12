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
- Lab: container `repllab` on `127.0.0.1:11980`, started by `lab/start.sh 2022` when `podman ps` does not show it. Tests and scripts create only objects named `m_` (databases, tables, publications, profiles, logins, jobs, backup files), remove them in `t.Cleanup` or the script's cleanup even on failure, and touch the lab's own objects (`Sales`, `SalesSub`, `SalesPub`, `SalesRef`, `lab-distrib`) only by reading. `MSreplservers` keeps its five known rows. SQL Server is stopped with `SHUTDOWN WITH NOWAIT`. Tasks 2 and 13 stop and restart `repllab` and leave it as they found it; no other container is touched but the `m-fresh` container Task 13 creates and removes.
- After each task, append the replication behaviors it measured to `docs/analysis/replication-oddities.md` and to `~/Sources/Repos/atelier/formations/docteur_atomic/sqlserver-replication/research/APPORTS-SQLREPL.md` (memory `course-notes-feed`), in the form those files use.

## Review Focus

1. An interrupt (`Ctrl-C`, `SIGTERM`) during a statement or during the wait for deliveries: every snapshot job apply disabled is enabled again before the process exits, and the output names any it could not restore. Pinned by `TestLabApplyInterruptRestores` (Task 12) and `TestLabRestoreAfterCancel` (Task 7).
2. Two `apply` runs on the same publication database at once, or an `apply` while the first waits at its prompt: the second refuses before reading anything. Pinned by `TestLabApplyLockRefusesSecond` (Task 12) and `TestLabAppLock` (Task 6).
3. A secret whose value holds `'`, `;`, `--` or is empty: bound as a parameter, never spliced; an empty value refuses the run before the prompt. Pinned by `TestLabSecretBinding` (Task 6), `TestLabApplySecret` (Task 12) and `TestApplyRefusesEmptySecret` (Task 9).
4. A snapshot run that someone else started between two operations, or a distribution job that `sp_addpushsubscription_agent` has just started: 22022, 21854 and 21861 are waited out within `-wait`, never reported as a failure of the plan. Pinned by `TestClassify` (Task 6), `TestRetryDecision` (Task 6) and `TestLabApplySnapshotAlreadyRunning` (Task 12).
5. `apply` run again after an `apply` that failed halfway: it plans the remainder, completes it and converges. Pinned by `TestLabApplyResumesAfterFailure` (Task 12).

## Rulings made in this plan

R1 to R41 are plan 3's (`docs/superpowers/plans/2026-11-12-sqlrepl-3-planner.md`); the numbering continues. Each ruling gives its reason and its cost if wrong once, here.

- R42 Scope. Plan 4 builds `apply` and its waits; it writes no snapshot report and adds no `-report` or `-sample-tail` flag (plan 5, with `sqlrepl snapshot`). Spec "The report" says every snapshot `apply` starts produces one: until plan 5, `apply` prints each delivery's outcome instead. Reason: the report is its own subsystem (blocking sampler, file listing, HTML), and apply is complete and testable without it. Cost if wrong: a gap Rudi may not accept, listed as an open question.
- R43 Package. `internal/apply` holds the session (pinned connections), the execution of statements, the error classes, the lock, the job handling, the deliveries owed and `Run`. Every decision that reads no server is a pure function with a unit test (`classify`, `retryDecision`, `effectQuery`, `parseDelivered`, `acceptRun`, `exitCode`, `restoreFor`); every server effect has a lab test.
- R44 Order of a run (spec "apply" steps 1 and 2). Apply connects as `plan` does, takes the lock (R45), then reads, prechecks and builds the plan once (`Target.Plan`), prints `Summary()`, and stops before any operation, with exit 1 and nothing run, when the plan is refused, when a precondition is `failed` or `unchecked` among those apply needs (R58), or when a secret is not set (R54). An empty plan prints `Plan for <publisher>.<database>: no changes.`, asks nothing, exits 0. Otherwise it asks, exactly: `Apply <n> operations to <publisher>.<database>, <c> costly (<cost> <k>, ...)? Type yes to apply: `, the parenthesis listing `Totals.ByCost` in `costOrder` without `online` and left out when `<c>` is 0. Only the line `yes` applies; anything else prints `Apply cancelled.` and exits 1. `-auto-approve` skips the question; without it and without a terminal on standard input (`os.Stdin.Stat()` has no `os.ModeCharDevice`), apply exits 2 before connecting: "apply needs a terminal to confirm, or -auto-approve". Reason: spec step 2; Terraform's convention for the cancel. Cost: none.
- R45 Application lock. On the publisher's pinned connection, in the publication database, before the read: `EXEC @rc = sp_getapplock @Resource = N'sqlrepl apply', @LockMode = N'Exclusive', @LockOwner = N'Session', @LockTimeout = 0`; `@rc < 0` refuses, exit 1, `another sqlrepl apply holds the lock on <server>.<database>`. Released by `sp_releaseapplock` at the end and by the end of the session. Divergence from the spec, recorded: the spec takes it "before its first operation there"; taking it before the read keeps a second apply from planning against a state the first is changing, and holds it through the prompt. One file is one publication database (spec "Unit and format"), so one lock per run. Measured by `TestLabAppLock` (Task 6): a second session is refused, the lock survives a refused call, its `ROLLBACK` and a `USE master` on the holder, and is released when the holder closes. Cost if wrong: a second apply that waits on the prompt of the first instead of refusing, which the test sees.
- R46 Execution. One `*sql.Conn` per server name compared without regard to case (R7), taken from the first pool `Servers` registers for that name and kept for the whole run; apply's reads at that server use the same connection, in order, from one goroutine. Before a statement, `USE <quoted database>` when the connection's current database differs. The statement runs as `conn.ExecContext(ctx, st.Text, args...)`, `args` one `sql.Named(strings.TrimPrefix(v.Var, "@"), value)` per `st.Secrets` entry (plan 3 ledger, never run through apply before). After every statement, success included, apply reads `@@TRANCOUNT` on that connection; above 0 it runs `IF @@TRANCOUNT > 0 ROLLBACK` and the statement is a failure ("left a transaction open"), even when the driver returned no error (`replication-oddities` "A refused call and its transaction": `@@ERROR` is 0 after some refusals). A statement runs under the interrupt context only; the waits run under the `-wait` budget too (R52).
- R47 Error classes, `classify(err error) (class, number int)`: `22022` busy job (both wordings, "already running" and "already has a pending request"; the Agent-stopped wording of Task 2, R56, is `agentStopped`); `21854` and `21861` generating; `18752` log reader; `1205` deadlock; any other number or a non-`mssql.Error` other. Per class, after the rollback of R46:
  - `18752` on the procedures of `effectQuery` (`sp_droppublication`, `sp_droparticle`, `sp_dropsubscription`, `sp_changepublication @property = N'sync_method'`, `sp_articlefilter`, `sp_replicationdboption @value = N'false'`): when `@@TRANCOUNT` was 0, apply runs the operation's re-read; done, the step succeeds with the note `18752 tolerated, <what> re-read`; not done, it is a failure. `@@TRANCOUNT` above 0 is a failure. On any other procedure 18752 is a failure. Re-reads, each a `SELECT` in the operation's database on its connection: the publication absent from `syspublications`; the article absent from `sysarticles`; no `syssubscriptions` row left for the subscription (and article when `@article` is not `N'all'`); `syspublications.sync_method` equal to the code of the call's `@value`; `sysarticles.filter_clause` equal to the call's clause (NULL for a NULL `@filter_clause`) and the filter procedure present (absent for NULL); `sys.databases.is_published = 0`. Sources: `CLAUDE.md` "Traps of the planner", ledger lines 93, 213, 229.
  - `21854`, `21861`: wait for the publication's snapshot job to be idle (R48), read `immediate_sync_ready`, retry the statement once when `retryDecision(passesInvalidateFlag, ready)` is true (`ready` false, or the call passes `@force_invalidate_snapshot = 1`); a retry that is not allowed, and a second refusal, are failures (spec step 3).
  - `22022`: only on the snapshot starts and the `job_start` statements (R49, R51); on any other statement a failure.
  - `1205` and other: failure, stop (spec "apply", 1205).
- R48 Jobs. After a `job_disable` statement, apply waits until the job is idle: it polls, every second within the budget, `<the operation's Call.Prologue>` followed by `SELECT CASE WHEN <plan.JobIdle> THEN 1 ELSE 0 END`, a read built from the printed parts. Each executed `job_disable` arms its restore, the plan's `job_restore` with the same `Path` (`restoreFor`, R61 for a dropped publication). On success the restores run in plan order like any statement. On every other way out (a failure, the budget spent, an interrupt), apply runs every armed restore not run yet, in plan order, under a fresh context bounded by `-timeout`, with `@@TRANCOUNT` cleared first; a connection error makes it reconnect once (a new pinned connection from the same pool) and retry that restore; what still fails is listed in `Result.JobsLeftDisabled` and printed `job left disabled: <path>`. `SIGINT` and `SIGTERM` are caught for the whole run; a second signal during the restores is ignored. Source: spec step 3.
- R49 Snapshot starts. A `generate_and_wait` statement (`sp_startpublication_snapshot`) that fails with 22022 is retried every second after the job reads idle, within the budget (ledger line 204). A `job_start` of a snapshot agent runs its guarded statement; apply then reads the job: when a run requested or started after the statement exists, the start is done; otherwise the guard skipped it (a run was in progress, someone else's, `TestLabJobStartGuardPush`), and apply waits for that run to end, reads whether the publication is still pending (`pendingQuery`: a `syssubscriptions` row at status 1, or without `immediate_sync` a subscribed article without the active bit, R12) and runs the statement again only then, once per wait, within the budget. 22022 from the statement itself (the race R24 names) is the same as a skipped guard. Two starts of one publication are never issued at once (`replication-oddities` "Two snapshot starts at once"). Spec step 5: "writes no report for a run it did not start" holds trivially under R42.
- R50 Deliveries owed. The planner marks them (Task 4): `Operation.Owes` (subscription keys) and `Operation.OwesAt` (`before`, `after` or `marked`), and `Plan.OwedBefore`. Apply records, for each, on the distributor's connection: T (`SYSDATETIME()`), the mark (`MAX(timestamp)` of `MSdistribution_history`), the listing of the publication's snapshot folder (R50 folder rule below) and whether its snapshot job runs; `before` right before the operation (for a push `subscription` add, before the unit, never between `sp_addsubscription` and `sp_addpushsubscription_agent`), `after` right after it, `marked` by reading the subscription rows' status (`syssubscriptions`, its own rows, `srvid >= 0`) before and after the call on the publisher's connection and keeping only the subscriptions that went from 2 to 1. A subscription the plan creates gets its status read on the first statement after the unit (pull: after the publisher-side `sp_addsubscription`); status 2 there is the `S7` case. A delivery is confirmed by a `MSdistribution_history` row of the subscription's agent (its `MSdistribution_agents` row by publisher id, publisher database, subscriber through `{servers}`, subscriber database, publication or `N'ALL'`) with `timestamp` above the mark, `time >= T` and `comments` parsed by `parseDelivered` into `unc\<name>\<run>\`, `<name>` the publication's folder and `<run>` accepted by `acceptRun`: any run of the publication for an `S7` subscription; otherwise a run absent from the listing at T, and, when the snapshot job ran at T, by the outcome of Task 3 row `DL.inprogress` (spec rule, or the conservative one). Under `concurrent` and `concurrent_c` the subscription's `MSsubscriptions` rows must also read status 2. The publication's folder name is read from any "Delivered snapshot" line of the publication's subscriptions, or from the single folder under `<root>/unc/` whose name ends with `_<publication database>_<publication>` without regard to case; none or several: unconfirmed, "snapshot folder of <publication> not identified". `<root>` is `Plan.SnapshotRoots[publication]`, listed with `sys.dm_os_enumerate_filesystem(@path, N'*')` at the distributor; a listing that fails: unconfirmed, naming the folder. History is polled every second (every 250 ms if `DL.rewrite` measures a rewrite faster than a second), every "Delivered snapshot" line seen is kept with its text and time, and confirmation reads what was kept. A pull subscription follows `DL.pull.delivered_line`: `yes`, as push; `no`, unconfirmed with its job state at the subscriber. A shared agent's re-added subscription follows `DL.shared_readd` the same way. Source: spec "Deliveries owed".
- R51 Distribution agent starts. The plan's `job_start` statements of distribution and pull agents in step 12 are not run in plan order: each runs when the generation its subscription's owed delivery waits for has ended (at once for `S7`), that is when the publication's snapshot job, started by R49 after T, reads idle again; a `job_start` with no delivery owed (a subscription pending before the plan) runs after that publication's generation alike. If the job reads idle while the delivery is still owed and the budget remains, the statement runs once more, and not again (spec step 5). 22022 means running. The deferral's `job_start` statements of step 9 run in plan order after `generate_and_wait`, once its run has ended; before the first operation after them that is not a `job_start`, apply waits for every delivery the publication owes so far (the subscriptions `generate_and_wait` names, Task 4). Timeout or a failed run there stops apply with `immediate_sync` off, the remaining operations unrun, exit 3 (spec "-defer-full-snapshot" step 3).
- R52 Budget and exit codes. `-wait` (default `30m`) starts at the first operation and bounds every wait (idle job, retry, generation, deliveries); spent, apply stops at once, restores (R48), and lists what remains and every delivery owed with its state. `-wait 0` runs every operation and every start, waits for nothing, and lists every delivery owed as `not awaited`. Exit codes, for both commands:

| Code | `plan` | `apply` |
|---|---|---|
| 0 | printed, no refusal, no failed precondition | nothing to do; or every operation ran and every delivery owed is confirmed |
| 1 | an error or a refusal | an error, a refusal, a failed or unchecked precondition it needs, a secret not set, the lock held, `Apply cancelled.`, a failed statement, or operations left unrun (interrupt, budget spent before the last operation) |
| 2 | a usage error | a usage error, or no terminal without `-auto-approve` |
| 3 | not used | every operation ran and a delivery owed is unconfirmed or not awaited; or the deferral's wait timed out or its run failed |
| 4 | printed with a failed precondition and no refusal (minor 9 of the plan 3 final review) | not used |

- R53 What is printed while running, on standard output, each line a template with exact fixed words:
  - `lock taken on <server>.<database>`
  - the summary, the question (R44);
  - per statement, before it runs: `[<seq>/<n>] <action> <kind> <path> at <server>, database <database>`, then the statement text, each line indented two spaces (spec anti-goal 2, "logs each statement before running it"); after it: `  ok (<ms> ms)`, `  18752 tolerated, <what> re-read`, `  retried after <class>`, or `  failed: Msg <number>: <message>`;
  - per wait, when it starts: `waiting for the snapshot job of <publication> to be idle`, `waiting for the deliveries of <publication>`;
  - per agent start: `started <kind> <publication>[ <subscriber>/<database>]` or `<kind> ... already running`;
  - per delivery owed, at the end: `delivery <publication> to <subscriber>/<database>: confirmed (run <run>)`, `: unconfirmed (<reason>; job <state>; last history: <comments>)` or `: not awaited`;
  - last: `Applied <ran> of <n> operations; deliveries: <k> confirmed, <u> unconfirmed, <a> not awaited.`, preceded on failure by `Failed at operation <seq>: Msg <number>: <message>` and `Remaining: <seq list>`, and by the `job left disabled` lines.
  Server informational messages are not printed. Errors that end the run before any operation go to standard error with the `sqlrepl:` prefix, as today.
- R54 Secrets. An empty environment variable is not set, for `plan` (`SecretSet`) and `apply` (`Options.Secret`) alike (ledger line 193). `apply` refuses before the prompt while a secret of the plan is not set: `secret <NAME> is not set` per secret, exit 1.
- R55 msdb job permission (spec step 3, R24's `unchecked` precondition). `precheck` reads, at the distributor and at each reached subscriber that runs a pull agent job, `IS_SRVROLEMEMBER(N'sysadmin')` and, in `msdb`, `IS_ROLEMEMBER(N'SQLAgentOperatorRole')`. The rule is set by Task 1 rows `AP.perm.*`: when the operator login without ownership could disable, enable and start a replication job and read the prologue's tables, the precondition is `ok` for a sysadmin or an operator; otherwise for a sysadmin only, and the detail names what the operator was refused. Not read (unreachable server): `unchecked`.
- R56 SQL Server Agent running. `precheck` reads, at the same servers as R55, the query Task 2 selects (the first candidate of `AS.detect.*` that reads differently with Agent running and stopped); the precondition `sql server agent` is `ok` or `failed` ("SQL Server Agent is not running: the jobs apply starts would not run"). If no candidate tells them apart, the precondition is `unchecked` with that detail, and apply relies on R47's `agentStopped` class to stop with a clear message. The plan 3 parked item "guard with SQL Agent stopped reads busy" is answered by `AS.guard.stopped`.
- R57 LSN initialization (spec "Subscriptions", `10-init-modes I3`, R21's refusal lifted). A subscription the plan creates with `initialization: lsn` needs `lsn`, written `0x` and 20 hexadecimal digits (`binary(10)`, the form `sp_addsubscription @subscriptionlsn` takes, `10-init-modes.sh` line 199); it is created only when its `state.LSNCheck` is `Valid`: not zero; not beyond the publication database's log end (`sys.dm_db_log_stats(DB_ID(<publication database>)).log_end_lsn` at the publisher, `vlf:block:slot` converted by `lsnFromLogEnd`); not before the lower bound, the `last_lsn` of the backup the subscriber database was last restored from (its `msdb.dbo.restorehistory` row joined to `backupset` at the subscriber, the numeric converted by `lsnFromNumeric` with the exact arithmetic of `10-init-modes.sh` lines 194 to 199 and checked to round-trip), that backup being of the publication database (Task 1 row `AP.lsn.backupset_database` decides whether `server_name` is compared too). No restore history, a subscriber not reached, or a log end not read: `Checked` false, refused, "the LSN of %s cannot be checked: %s". `allow_initialize_from_backup` follows Task 1 row `AP.lsn.no_backup_flag`: refused with that error number, normalization fills it true as a prerequisite (spec "Omitted properties", prerequisites); `ok`, nothing. Reason: a wrong LSN was accepted silently and stopped every subscription of the database (`lab/README.md`, "Initialization without a snapshot"). The extension of an `lsn` subscription stays refused (R21).
- R58 Preconditions and exit code (minor 9). `plan` exits 4 when it printed a plan with a `failed` precondition and no refusal. `apply` refuses (R44) on any `failed` precondition, and on an `unchecked` `msdb job permission` or `sql server agent` at a server where it runs a job operation. Other `unchecked` preconditions do not refuse: R29 keeps push operations planned for an unreachable subscriber, and dropping the subscription of a subscriber that is gone is a repair apply must allow. Divergence, recorded: spec "Non-goals" has `plan` only warn on a missing snapshot folder; apply refusing it costs a rerun after the folder is made, where running would end in a failed snapshot and exit 3. Open question for Rudi.
- R59 The other parked minors of the plan 3 final review. Minor 7: a warning on an operation that adds a column to an article whose `pre_creation_cmd` is `delete`, `truncate` or `none` ("the subscriber table of %s keeps its columns: the delivery fails with Invalid column name until the column is added there"); a warning on a new article whose destination schema is not `dbo`, whose `schema_option` lacks `create_schemas` (0x8000000), and whose schema a `SchemaCheck` reads absent or unchecked at the subscriber ("schema %s does not exist at %s/%s: the delivery fails"). Minor 11: a change of `destination` that differs only in case keeps its cost and gets the warning "destination %s differs only in case: the subscriber table is dropped and created again". Minor 12: `precheck.Run` takes the current configuration and checks the distributor's current `working_directory` when the file omits it. Minor 13: an operation with a non-empty `Shared` prints ` (shared with <list>)` after its costs in the summary, and a drop of a shared object (cost `shared_object_changed`, action `drop`) counts in `Totals.Costly`.
- R60 Convergence through apply. The harness keeps its environment, files and data checks, and replaces `run`, `startAndWait`, `startPull`, `startSnapshot` and `dropWith18752` by `e.apply(t, des, opt) *apply.Result`, which calls `apply.Run` with every server of the file mapped to the lab pool, `AutoApprove`, `Wait` 5 minutes, output to `t.Log`; it fails the test unless the outcome is the one the test expects (`applied` with every delivery `confirmed`, by default). The scenarios' plan assertions stay on `e.plan`; the data checks follow the run. `waitDelivered` stays as a data check with a short timeout, since apply has already confirmed the delivery.
- R61 The restore of a dropped publication's job. Today the plan emits a `job_disable` and no `job_restore` for a publication it drops, so a failure before the drop would leave the job disabled. The plan emits, in step 12, a `job_restore` for it with the value found, whose prologue looks the job up without the `THROW` and whose `Guard` is `@job_id IS NOT NULL`: run as printed after the drop, it does nothing; run by R48 on an early way out, it restores. `restoreFor` arms it like any other.

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
- [ ] Step 4: README section: what each row decides (R55 from `AP.perm.m_ap_oper.*`, R57 from `AP.lsn.*`), and `AP.disabled_schedule`. If `runs` is above 0, stop and report: spec step 3's claim that a disabled job starts no scheduled run is false, and R47's 21854/21861 retry becomes the only guard. Commit.

### Task 2: SQL Server Agent stopped

Files:
- Create: `lab/agent-stopped.sh`, `lab/results/2022/agent-stopped.txt`
- Modify: `lab/README.md`

Interfaces:
- Produces rows `R|AS.<case>|<result>|<detail>`, read by R56 and by `classify` (R47).

- [ ] Step 1: Write the script, run directly like `lab/distributor-defaults.sh` (it stops the lab, so not through `lab/campaign.sh`). With Agent running, then stopped, read each candidate: `AS.detect.dm_server_services.<state>` (`status_desc` of the `sys.dm_server_services` row whose `servicename` starts with `SQL Server Agent`, or `none`); `AS.detect.agent_sessions.<state>` (count of `sys.dm_exec_sessions` with `program_name LIKE N'SQLAgent - %'`); `AS.detect.xp_servicecontrol.<state>` (`EXEC master.dbo.xp_servicecontrol N'QueryState', N'SQLServerAGENT'`: its output or the error number). With Agent stopped: `AS.guard.stopped` (`plan.JobIdle` evaluated for `SalesPub`'s snapshot job: `idle` or `busy`); `AS.start_job.stopped` (`msdb.dbo.sp_start_job` on that job: error number and the message's first 80 characters); `AS.startpub.stopped` (`sp_startpublication_snapshot @publication = N'SalesPub'` in `Sales`: return code, error number and message). Stop Agent with `podman exec repllab /opt/mssql/bin/mssql-conf set sqlagent.enabled false`, `SHUTDOWN WITH NOWAIT`, `podman start repllab`, wait for the instance; restore with `sqlagent.enabled true` and the same restart, then wait until `SalesPub`'s snapshot agent has a run that ended after the restart, as `lab/start.sh` waits, and check that `TestLabSalesPlanEmpty` passes. A trap restores Agent on failure.
- [ ] Step 2: Run it, in one shell with the password loaded. Expected: exit 0, `R|TOTAL|9`, and afterwards `lab/gotest.sh '^TestLabSalesPlanEmpty$' ./internal/convergence` gives 1 `--- PASS`.
- [ ] Step 3: Break step. Make the trap skip the restore of `sqlagent.enabled`, run, see `TestLabSalesPlanEmpty` fail or the script's final check fail; restore Agent by hand, restore the trap.
- [ ] Step 4: README section: which candidate R56 uses (or none), the message `classify` reads for `agentStopped`. Commit.

### Task 3: Delivery confirmation sources

Files:
- Create: `lab/campaign/21-deliveries.sh`, `lab/results/2022/21-deliveries.txt`
- Modify: `lab/README.md`

Interfaces:
- Produces rows `R|DL.<case>|<result>|<detail>`, read by R50 and Task 8.

- [ ] Step 1: Write the script. Database `m_dl_db`, tables `m_t1` to `m_t3` (`id int PRIMARY KEY, a int`), `m_t1` with 200000 rows so that a generation lasts several seconds, the others 20; subscriber databases `m_dl_sub1` to `m_dl_sub4`. Cases:
  - `DL.pull.delivered_line`: publication `m_dl_pp` (`allow_pull`, `independent_agent`), a pull subscription to `m_dl_sub1`, snapshot generated, then the pull agent job started at the subscriber; within 120 s: `yes` when `MSdistribution_history` at the distributor has a "Delivered snapshot" row for the pull agent's `MSdistribution_agents` row, `no` otherwise, with `subscriber_rows=<n>` read at the subscriber.
  - `DL.rewrite`: publication `m_dl_pr` (continuous push agent to `m_dl_sub2`); from the snapshot start, sample `id`, `timestamp`, `time` and `comments` of the agent's history every 250 ms for 60 s after the "Delivered snapshot" row first appears: `kept` when that row (`id`) keeps its comments, `rewritten_after_ms=<n>` otherwise.
  - `DL.inprogress`: publication `m_dl_pi` (`native`, no `immediate_sync`, push to `m_dl_sub3`, delivered, agent continuous); start a snapshot, and while its history shows it generating `m_t1`, call `sp_changearticle @property = N'schema_option'` with the reinit flag on `m_t2` (status 2 to 1); after the run: `status_after_run=<1|2>`, `delivered_from=<in_progress|none>` (the next "Delivered snapshot" line names the in-progress run folder or none within 60 s), `subscriber_option=<old|new>` (whether the delivered `m_t2` carries the change, read from the subscriber's index set).
  - `DL.s7_frequent`: publication `m_dl_ps` (`immediate_sync`, snapshot every minute, delivered); a push subscription added to `m_dl_sub4`, agent continuous: `folder=at_T|after_T` for the folder its "Delivered snapshot" line names against the listing at the call.
  - `DL.shared_readd`: publication `m_dl_pn` (no `independent_agent`), push subscription to `m_dl_sub4` delivered by the shared agent; dropped, re-added with snapshot initialization, generated: `yes` when a new "Delivered snapshot" line of the shared agent above the mark taken before the re-add names `m_dl_pn`'s folder, `no` otherwise.
  Cleanup removes everything, the shared agent included.
- [ ] Step 2: Run, in one shell: `lab/campaign.sh 2022 lab/campaign/21-deliveries.sh`. Expected: exit 0, `R|TOTAL|5`.
- [ ] Step 3: Break step. Skip the drop of `m_dl_sub4`: `GUARD residue failed`. Restore, rerun.
- [ ] Step 4: README section. Write down what each row decides: `DL.pull.delivered_line` the pull branch of R50; `DL.rewrite` the poll interval; `DL.inprogress`: `status_after_run=1`, or `delivered_from=in_progress` with `subscriber_option=new`, keeps the spec's rule for a run in progress at T; `delivered_from=in_progress` with `subscriber_option=old` makes `acceptRun` refuse every run in progress at T (apply then starts a run of its own, R49); `DL.shared_readd` the shared branch. Commit.

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

type Owed struct {
	Publication  string `json:"publication"`
	Subscription string `json:"subscription"`
}

const JobIdle = "..." // renamed from jobIdle, same text
```

- Owes, set in `finish` from the predicted state: a push `subscription` add with `snapshot` initialization, `[key]`, `before`; the publisher-side `sp_addsubscription` of a pull subscription with `snapshot`, `[key]`, `after`; an `article` add on an `immediate_sync` publication, every snapshot-initialized subscription it gives a status 1 row, `after`; a `subscription_extension` of a snapshot-initialized subscription, `[key]`, `after`; an operation costed `reinitialization` (re-adds of R34 aside, which are subscription adds), its `Affects.Subscriptions`, `marked`. `replication_support_only`, `backup` and `lsn` subscriptions are owed nothing. `OwedBefore`: the subscriptions with a row at 1 (or an inactive subscribed article without `immediate_sync`) in the state before the plan. `generate_and_wait`: `Affects.Subscriptions` the subscriptions extended in the deferral's step 2, `Owes` empty.
- R61's `job_restore` of a dropped publication; R59's minors 7a, 11, 13; R54 in `cmd/sqlrepl/plan.go` and the harness (`v, ok := os.LookupEnv(name); ok && v != ""`).

- [ ] Step 1: Write the tests. `TestOwesSubscriptionCreation`: a new push subscription with `snapshot` on `SalesRef` has `Owes` its key and `OwesAt` `before` on its `sp_addsubscription`, nothing on its `sp_addpushsubscription_agent`; a pull one has them on the publisher-side call with `after`; a `replication_support_only` one has none. `TestOwesAddArticle`: on ready `SalesPub` the `sp_addarticle` owes every subscription, `after`; on `SalesRef` the `sp_addarticle` owes nothing and the extension owes its subscription. `TestOwesReinitMarked`: a `schema_options` change of `Customer` on `SalesPub` with the reinit flag owes `Affects.Subscriptions`, `marked`. `TestOwedBefore`: a fixture subscription row set to 1 gives one `Owed`; the fixture as is gives none. `TestGenerateAndWaitNamesSubscriptions`: the deferral of `TestDeferSequence` names the extended subscription. `TestPlanDistributionAndRoots`: from the fixture, `DistributionDB` is `distribution` and each publication's root the distributor's working directory, or its `alt_snapshot_folder` when set. `TestJobRestoreOfDroppedPublication` (R61): a dropped publication gets a step 12 `job_restore` whose prologue has no `THROW`, whose `Guard` is `@job_id IS NOT NULL`, with `@enabled` the value found. `TestColumnAddWarnsPreCreation`: adding a column to an article with `pre_creation_cmd` `delete` warns with the minor 7 text, with `drop` does not. `TestDestinationCaseOnlyWarns`: `t1` to `T1` warns with the minor 11 text and keeps `subscriber_data_replaced`. `TestSummarySharedAndCostly`: a dropped profile with `Shared` `[X.Other]` prints `(shared with X.Other)` and `Totals.Costly` is 1. `TestPlanSecretEmptyNotSet` (`cmd/sqlrepl`): a secret variable set to `""` is listed `not set`.
- [ ] Step 2: Run `go test -count=1 -v -run '^(TestOwesSubscriptionCreation|TestOwesAddArticle|TestOwesReinitMarked|TestOwedBefore|TestGenerateAndWaitNamesSubscriptions|TestPlanDistributionAndRoots|TestJobRestoreOfDroppedPublication|TestColumnAddWarnsPreCreation|TestDestinationCaseOnlyWarns|TestSummarySharedAndCostly)$' ./internal/plan` and `go test -count=1 -v -run '^TestPlanSecretEmptyNotSet$' ./cmd/sqlrepl`. Expected: compile failures.
- [ ] Step 3: Implement; regenerate the golden files with `-update` and read their diff: only the new fields, the R61 restore and the summary suffixes may change.
- [ ] Step 4: Run the Step 2 commands. Expected: 10 and 1 `--- PASS`. Then `go test ./...`.
- [ ] Step 5: Break step. Set `OwesAt` `after` on the push `sp_addsubscription`: `TestOwesSubscriptionCreation` fails. Restore. Keep the `THROW` in R61's prologue: `TestJobRestoreOfDroppedPublication` fails. Restore. Count `shared_object_changed` drops as online: `TestSummarySharedAndCostly` fails. Restore.
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
func checkLSN(lsn, lower, logEnd [10]byte) (ok bool, reason string)
```

- Plan consumption (`lists.go`): `msdb job permission` and `sql server agent` preconditions per server with job operations, from `Checks` by R55 and R56, `unchecked` when absent; the R57 creation of an `lsn` subscription (`@sync_type = N'initialize from lsn'`, `@subscriptionlsn` the bare `binary(10)` literal, encoder added and the `neverPassed` entry removed) when its `LSNCheck` is `Valid`, the refusal with its `Reason` otherwise; R59 minor 7b's warning from `Schemas`. `r21Lsn` is removed.

- [ ] Step 1: Write the tests. `TestParseLSN`: `0x00000025000001080001` parses; `0x0025`, `00000025000001080001` and `0xZZ...` are errors. `TestLSNFromNumeric`: `37000000026400001` gives `00000025 00000108 0001`; a numeric whose slot exceeds 65535 is an error. `TestLSNFromLogEnd`: `00000025:00000108:0001` gives the same bytes. `TestCheckLSN`: zero refused; above the log end refused; below the lower bound refused; equal to the lower bound accepted (`I3.lsn.create` used the backup's own `last_lsn`). `TestChecksJSONKeys` gains the four types. `TestBuildLSNSubscription`: a valid check gives `sp_addsubscription` with `@sync_type = N'initialize from lsn', @subscriptionlsn = 0x00000025000001080001`; an invalid one the refusal with its reason; no check the refusal "cannot be checked". `TestBuildJobPreconditions`: sysadmin `ok`; neither role `failed`; operator by the R55 outcome; no check `unchecked`; Agent not running `failed` with R56's detail. `TestBuildSchemaMissingWarns`. `TestPrecheckFolderFromCurrent`: a file without a distributor and a current one with a working directory gives a checked folder. `TestPrecheckQueriesParse` gains every new query. `TestLabPrecheckApply` (lab): as `sa`, the lab's server reads `Sysadmin` true and Agent `Running` true; a `SchemaCheck` of `dbo` in `SalesSub` exists, of `m_nos` does not.
- [ ] Step 2: Run `go test -count=1 -v -run '^(TestParseLSN|TestLSNFromNumeric|TestLSNFromLogEnd|TestCheckLSN|TestPrecheckFolderFromCurrent)$' ./internal/precheck`, `go test -count=1 -v -run '^TestChecksJSONKeys$' ./internal/state` and `go test -count=1 -v -run '^(TestBuildLSNSubscription|TestBuildJobPreconditions|TestBuildSchemaMissingWarns)$' ./internal/plan`. Expected: compile failures.
- [ ] Step 3: Implement. The queries are constants of `queries.go`; the lower bound is read at the subscriber's connection, the log end on `Conns.Publisher`.
- [ ] Step 4: Run the Step 2 commands: 5, 1 and 3 `--- PASS`; then `lab/gotest.sh '^(TestPrecheckQueriesParse|TestLabPrecheck|TestLabPrecheckApply)$' ./internal/precheck` (3). Then `go test ./...`.
- [ ] Step 5: Break step. Accept an LSN equal to the log end plus one: `TestCheckLSN` fails. Restore. Convert the numeric with the brief's formula (`CAST(lsn / 1e15 AS binary(4))`, `10-init-modes.sh` line 201) in Go: `TestLSNFromNumeric` fails. Restore. Make a missing permission check `ok`: `TestBuildJobPreconditions` fails. Restore.
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
func (s *session) close()
// exec runs one statement by R46 and returns the driver error, or
// errTranOpen when it succeeded and left a transaction, rolled back.
func (s *session) exec(ctx context.Context, st plan.Statement, secret func(string) (string, bool)) error

type class int // classOther, classBusy, classAgentStopped, classGenerating, classLogReader, classDeadlock
func classify(err error) (class, int)
func retryDecision(passesInvalidateFlag, ready bool) bool
func effectQuery(op plan.Operation) (query string, args []any, ok bool) // R47 re-reads
func secretArgs(st plan.Statement, secret func(string) (string, bool)) ([]any, error)

func lock(ctx context.Context, conn *sql.Conn, database string) error // R45; errLocked when held
func unlock(ctx context.Context, conn *sql.Conn) error
```

- [ ] Step 1: Write the tests. Unit: `TestClassify`: `mssql.Error` 22022 with each wording is `classBusy`, with the `AS.start_job.stopped` wording `classAgentStopped`, 21854 and 21861 `classGenerating`, 18752 `classLogReader`, 1205 `classDeadlock`, 245 and a non-driver error `classOther`. `TestRetryDecision`: the four cells. `TestEffectQueryCovers`: an operation of each of the six procedures has a query, `sp_addarticle` has none; `sp_changepublication` with `@property = N'retention'` has none. `TestSecretArgs`: `@secret_1` of `SQLREPL_SQL_X` gives `sql.Named("secret_1", v)`; a secret the function does not return is an error naming `SQLREPL_SQL_X` and not containing the value of any other variable. Lab, on a database `m_ap_exec` the test creates and drops: `TestLabExecRollsBack`: the statement `BEGIN TRAN; RAISERROR(N'm', 16, 1);` returns the error and `@@TRANCOUNT` reads 0 afterwards; `BEGIN TRAN;` alone returns `errTranOpen` and 0 afterwards. `TestLabAppLock` (R45): a second connection's `lock` returns `errLocked`; still after the holder runs a refused `BEGIN TRAN; RAISERROR` and its rollback, and after the holder's `USE master`; after `close`, the second takes it. `TestLabSecretBinding`: a statement `IF @secret_1 <> N'a''b;c--d' THROW 50000, N'm', 1;` with the secret set to `a'b;c--d` succeeds; with another value fails with 50000. `TestLabExecUseOnChange`: three statements in `m_ap_exec` then one in `master` issue two `USE` (counted by a wrapper the test passes).
- [ ] Step 2: Run `go test -count=1 -v -run '^(TestClassify|TestRetryDecision|TestEffectQueryCovers|TestSecretArgs)$' ./internal/apply`. Expected: compile failure.
- [ ] Step 3: Implement.
- [ ] Step 4: Run the Step 2 command (4 `--- PASS`), then `lab/gotest.sh '^(TestLabExecRollsBack|TestLabAppLock|TestLabSecretBinding|TestLabExecUseOnChange)$' ./internal/apply` (4).
- [ ] Step 5: Break step. Skip the `@@TRANCOUNT` read after a successful statement: `TestLabExecRollsBack` fails on `BEGIN TRAN;`. Restore. Take the lock with `@LockOwner = N'Transaction'`: `TestLabAppLock` fails. Restore. Bind the secret under `@secret_1` (prefix kept): `TestLabSecretBinding` fails. Restore.
- [ ] Step 6: Commit.

### Task 7: Jobs and their restore

Files:
- Create: `internal/apply/jobs.go`, `internal/apply/jobs_test.go`
- Modify: `internal/apply/lab_test.go`

Interfaces:
- Consumes: `session` (Task 6), `plan.JobIdle`, the job operations' `Call.Prologue` (R24).
- Produces:

```go
func restoreFor(p *plan.Plan, disable plan.Operation) (plan.Operation, bool) // R48, R61
type jobs struct { armed []int /* Seq of restores */; ran map[int]bool }
func (j *jobs) arm(p *plan.Plan, disable plan.Operation)
// restoreRemaining runs the armed restores not run yet (R48) and returns
// the paths left disabled.
func (j *jobs) restoreRemaining(s *session, p *plan.Plan, timeout time.Duration, secret func(string) (string, bool)) []string
func idleQuery(op plan.Operation) string // Prologue + SELECT CASE WHEN JobIdle ...
func waitIdle(ctx context.Context, s *session, op plan.Operation, out io.Writer) error
func startedAfter(ctx context.Context, s *session, op plan.Operation, since time.Time) (bool, error) // a run requested or started after since
```

- [ ] Step 1: Write the tests. Unit: `TestRestoreFor`: from `TestBuildJobOperations`' plan, each `job_disable` maps to the `job_restore` of the same `Path`; a created publication's step 8 disable maps to its restore; a dropped publication's disable to R61's restore. `TestIdleQuery`: the query is the prologue, a newline, then `SELECT CASE WHEN ` + `plan.JobIdle` + ` THEN 1 ELSE 0 END;`. Lab, with a plain msdb job `m_ap_job` (one T-SQL step `WAITFOR DELAY '00:00:05'`) the test creates and deletes, and hand-written operations whose prologue finds it by name: `TestLabWaitIdle`: started, `waitIdle` returns after the step ends (between 4 and 30 s) and `startedAfter` reads true for a time before the start; `TestLabRestoreAfterCancel`: the job disabled by a `job_disable`-shaped statement, the run's context cancelled, `restoreRemaining` with a fresh timeout enables it (`sysjobs.enabled` 1) and returns nothing; `TestLabRestoreReconnects`: the pinned connection killed (`KILL <spid>` from another connection) before `restoreRemaining`, which reconnects once and enables the job.
- [ ] Step 2: Run `go test -count=1 -v -run '^(TestRestoreFor|TestIdleQuery)$' ./internal/apply`. Expected: compile failure.
- [ ] Step 3: Implement.
- [ ] Step 4: Run the Step 2 command (2 `--- PASS`), then `lab/gotest.sh '^(TestLabWaitIdle|TestLabRestoreAfterCancel|TestLabRestoreReconnects)$' ./internal/apply` (3).
- [ ] Step 5: Break step. Run the restores under the cancelled context: `TestLabRestoreAfterCancel` fails. Restore. Drop the reconnect: `TestLabRestoreReconnects` fails. Restore.
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
	T                         time.Time
	Mark                      []byte   // rowversion
	Listing                   []string // run folders at T
	RunningAtT, S7            bool
	Concurrent                bool
}
type Delivery struct {
	Publication, Subscription string
	Status                    string // confirmed, unconfirmed, not_awaited
	Run, Detail               string
}
func parseDelivered(comments string) (pubFolder, run string, ok bool)
func acceptRun(o owed, run string, listingAtRunEnd []string) bool
func pubFolder(lines []string, listing []string, database, publication string) (string, error)
type tracker struct { /* owed records, kept lines */ }
func (t *tracker) record(ctx context.Context, s *session, p *plan.Plan, pub string, subs []string) error // T, mark, listing, running
func (t *tracker) marked(ctx context.Context, s *session, op plan.Operation) (func(context.Context) ([]string, error), error) // statuses before; the returned func reads after, keeps 2 to 1
func (t *tracker) poll(ctx context.Context, s *session, p *plan.Plan) error // one pass: history after the marks, kept lines, MSsubscriptions status for the concurrent family
func (t *tracker) pending(pub string) []owed
func (t *tracker) results(notAwaited bool) []Delivery
```

- Queries in `queries.go`, each a constant with `{dist}` and `{servers}` substituted as the reader's `distQuery` does (`internal/reader/reader.go`): the agent row of a subscription (R50), the history after a mark, the subscription statuses at the publisher, the `MSsubscriptions` statuses, `pendingQuery` (R49), `immediate_sync_ready` (R47), the folder listing.

- [ ] Step 1: Write the tests. `TestParseDelivered`: `Delivered snapshot from the 'unc\REPLLAB_SALES_SALESPUB\20261111162904\' sub-folder in 812 milliseconds` gives `REPLLAB_SALES_SALESPUB` and `20261111162904`; a name with a space is kept (`O19`); any other comment is not ok. `TestAcceptRunFolder`: `S7` accepts a run present at T; a non-`S7` record refuses a run present at T and accepts one absent; a run in progress at T follows Task 3's `DL.inprogress` outcome (write the case the outcome dictates). `TestPubFolderIdentified`: one line names it; no line and one folder ending `_m_pdb_x_m_p` (any case) names it; two such folders are an error "not identified". `TestQueriesSubstituted`: no query keeps `{dist}` or `{servers}` for `distribution` and `m d]2`. `TestDeliveryResults`: `notAwaited` turns every pending record into `not_awaited`.
- [ ] Step 2: Run `go test -count=1 -v -run '^(TestParseDelivered|TestAcceptRunFolder|TestPubFolderIdentified|TestQueriesSubstituted|TestDeliveryResults)$' ./internal/apply`. Expected: compile failure.
- [ ] Step 3: Implement. Add every query of `queries.go` to a `TestApplyQueriesParse` (lab, `SET PARSEONLY ON` on a dedicated `sql.Conn`, as the reader's `TestQueriesParse`).
- [ ] Step 4: Run the Step 2 command (5 `--- PASS`), then `lab/gotest.sh '^TestApplyQueriesParse$' ./internal/apply` (1).
- [ ] Step 5: Break step. Accept a run present at T for a non-`S7` record: `TestAcceptRunFolder` fails. Restore. Compare the folder suffix with case: `TestPubFolderIdentified` fails. Restore.
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
type Outcome string // empty, refused, cancelled, applied, failed, unconfirmed
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
	Notes            []string // 18752 tolerated, retries
}
func Run(ctx context.Context, t Target, o Options) (*Result, error) // error: before the lock or the plan
func (r *Result) ExitCode() int
func question(p *plan.Plan) string // R44
```

- `Run` in order: session; lock (R45); `t.Plan`; print the summary; refusals, preconditions (R58) and secrets (R54) refuse; empty returns; confirm; budget from now; for each operation: owes `before` recorded, `BeforeStatement`, log (R53), execute by its kind (R46 to R49, R51 for the deferral), owes `after` or `marked`, `job_disable` arms and waits idle (R48); the distribution `job_start` statements of step 12 held for R51; after the last operation, the delivery wait (R50, R51) unless `-wait 0`; restores on every way out (R48); unlock; the last lines (R53).

- [ ] Step 1: Write the tests. `TestExitCode`: the R52 table, one case per row of the `apply` column, interrupt after the last operation included (3). `TestQuestion`: a plan of 5 operations, 2 costly (`new_snapshot` 1, `reinitialization` 1) gives exactly `Apply 5 operations to REPLLAB.Sales, 2 costly (new_snapshot 1, reinitialization 1)? Type yes to apply: `; with 0 costly, no parenthesis. `TestRunRefusals`, with a `Target` whose `Servers` map to a pool of a fake driver registered by the test (the precheck package's `fake_test.go` pattern) and whose `Plan` returns a given plan: a refused plan gives `refused` and no statement; a `failed` precondition `refused`; an `unchecked` `msdb job permission` `refused`; a secret the function does not return `refused` with `secret SQLREPL_X is not set`; an empty plan `empty`, `Confirm` never called; `Confirm` returning false gives `cancelled` and `Apply cancelled.`. `TestApplyRefusesEmptySecret`: `Secret` returning `"", true` is not set.
- [ ] Step 2: Run `go test -count=1 -v -run '^(TestExitCode|TestQuestion|TestRunRefusals|TestApplyRefusesEmptySecret)$' ./internal/apply`. Expected: compile failure.
- [ ] Step 3: Implement.
- [ ] Step 4: Run the Step 2 command. Expected: 4 `--- PASS`.
- [ ] Step 5: Break step. Ask the question before the precondition check: `TestRunRefusals` fails (the fake `Confirm` is called). Restore. Map an interrupt after the last operation to 1: `TestExitCode` fails. Restore.
- [ ] Step 6: Commit.

### Task 10: The apply command

Files:
- Create: `cmd/sqlrepl/apply.go`, `cmd/sqlrepl/apply_test.go`
- Modify: `cmd/sqlrepl/plan.go` (the shared wiring), `cmd/sqlrepl/main.go` (the `apply` command, exit codes), `cmd/sqlrepl/plan_test.go`, `README.md` (an `apply` section)

Interfaces:
- Consumes: `apply.Run`, `apply.Target`, `apply.Options`; the plan command's flag parsing and connection code.
- Produces: `func runApply(args []string, stdin io.Reader, stdout, stderr io.Writer) int`, the exit code; `runPlan` returns the R52 code too (4 on a failed precondition). `func prepare(ctx, f *planFlags) (*wiring, error)` and `func (w *wiring) compute(ctx context.Context, opt plan.Options) (*plan.Plan, error)`, the steps of today's `runPlan` from the probe to `Build`, shared by both commands; `wiring` holds the pools, closed by `w.close()`. `var applyRun = apply.Run` and `var isTerminal = func(f *os.File) bool` for the tests. `func confirmer(r io.Reader, w io.Writer) func(string) (bool, error)`: writes the question, reads one line, true only for `yes`.
- Flags: those of `plan` without `-sql` and `-json`, plus `-auto-approve`. `-wait` is R52's budget. Servers: the publisher name to the master pool, the distributor name to its pool, each subscriber to its pool (`Target.Servers`); the publication database's name from the probe. `Interrupt` from `signal.Notify` on `SIGINT` and `SIGTERM`.

- [ ] Step 1: Write the tests. `TestApplyFlags`: `-f x.yaml -auto-approve -wait 5m` parses; `-sql` is a usage error (exit 2). `TestApplyNoTerminal`: with `isTerminal` false and no `-auto-approve`, exit 2, the message of R44, and `connect` (faked) never called. `TestConfirmer`: `yes\n` true; `y\n`, `YES\n`, `` false; the question is written once. `TestApplyExitCodes`: `applyRun` faked to return each `Outcome`: the exit codes of R52. `TestPlanExitFour`: `buildPlan` faked to return a plan with a `failed` precondition and no refusal: `run` returns 4; with a refusal too, 1. `TestLabApplyCLISalesNoChanges` (lab): `runApply` with `-f ../../internal/testdata/lab/sales.yaml -auto-approve` and `-server` mapping the lab: exit 0, stdout holds `lock taken on` and `no changes.`, and no statement line.
- [ ] Step 2: Run `go test -count=1 -v -run '^(TestApplyFlags|TestApplyNoTerminal|TestConfirmer|TestApplyExitCodes|TestPlanExitFour)$' ./cmd/sqlrepl`. Expected: compile failure.
- [ ] Step 3: Implement. The plan 3 tests of `cmd/sqlrepl` keep passing unchanged except their call of `runPlan`'s return.
- [ ] Step 4: Run the Step 2 command (5 `--- PASS`), then `lab/gotest.sh '^(TestLabApplyCLISalesNoChanges|TestLabPlanCLISalesEmpty|TestLabPlanCLIReadOnly)$' ./cmd/sqlrepl` (3). Then `go build ./cmd/sqlrepl && go vet ./... && test -z "$(gofmt -l .)" && go test ./...`.
- [ ] Step 5: Break step. Check the terminal after connecting: `TestApplyNoTerminal` fails. Restore. Accept `y`: `TestConfirmer` fails. Restore.
- [ ] Step 6: README `apply` section: the order of a run, the question, the lock, the budget, the exit code table, what is printed, and that apply writes no report yet (R42). Commit.

### Task 11: Convergence scenarios through apply

Files:
- Modify: `internal/convergence/harness_test.go`, `internal/convergence/convergence_test.go`, `internal/convergence/strategies_test.go`

Interfaces:
- Consumes: `apply.Run` (Task 9). Produces `func (e *env) apply(t *testing.T, des *model.Config, opt plan.Options, want apply.Outcome) *apply.Result` (R60) and `func (e *env) target(des *model.Config, opt plan.Options) apply.Target`, whose `Plan` is `e.inputs` then `plan.Build`.

- [ ] Step 1: Replace every `e.run(t, p)` followed by `e.startAndWait(t, p)` (or alone) by `e.apply(t, des, opt, apply.Applied)`; remove `run`, `startAndWait`, `startPull`, `startSnapshot` and `dropWith18752`. A scenario's assertions on the plan stay on `e.plan` before the apply. After each apply, assert that `Result.Deliveries` holds one `confirmed` entry per subscription the scenario expects delivered (a pull subscription by Task 3's `DL.pull.delivered_line`: `confirmed`, or `unconfirmed` with the reason R50 gives), then the existing data checks.
- [ ] Step 2: Run, in one shell, `lab/gotest.sh '^TestLab' ./internal/convergence`. Expected: 18 `--- PASS` (the 7 of `convergence_test.go`, the 9 of `strategies_test.go`, the 2 of `jobstart_test.go`), and the teardown check of plan 3 Task 19 gives 0. A scenario that fails through apply but passed through the old harness is a defect of apply: find it in apply, never in the scenario's expectations.
- [ ] Step 3: Break step. Make apply run the step 12 distribution `job_start` statements in plan order instead of R51: `TestLabPullSubscription` fails (the pull agent started before the generation exits, the delivery stays unconfirmed). Restore. Make apply skip the delivery wait before the deferral's restore: `TestLabDeferFullSnapshot` fails. Restore.
- [ ] Step 4: Commit.

### Task 12: Apply scenarios on the lab

Files:
- Create: `internal/convergence/apply_test.go`, `internal/convergence/testdata/secret.yaml`, `internal/convergence/testdata/lsn.yaml`, `internal/convergence/testdata/lsn-setup.sql`
- Modify: `internal/convergence/testdata/teardown.sql` (the login `m_login_<name>`, the backup file and its history)

Interfaces:
- Consumes: the harness of Task 11; `apply.Options.BeforeStatement` (Task 9).
- Scenarios:
  - `TestLabApplySecret`: a SQL login `m_login_<name>` with a password holding `'`, `;` and `--`, mapped to `db_owner` of `{sub}`; `secret.yaml`, a push subscription with `connection.security: sql`, `login: m_login_<name>`, `password_secret: SQLREPL_SQL_M_LOGIN` (the test sets the variable): applied, delivered, converged; no output line holds the password.
  - `TestLabApplyLSN`: `lsn-setup.sql` backs `{db}` up `COPY_ONLY` and restores it over `{sub}`; the test reads the backup's `last_lsn`, converts it in SQL with the arithmetic of `10-init-modes.sh` lines 194 to 199, writes it into `lsn.yaml` (`initialization: lsn`, `lsn: 0x...`), applies: one `sp_addsubscription` with `@sync_type = N'initialize from lsn'`; rows inserted at the publisher after the apply reach `{sub}` (no snapshot), converged.
  - `TestLabApplyLSNRefused`: the same file with an LSN one above the log end, and a `BeforeStatement` hook that fails the test and returns an error at the first statement, so that a wrong LSN can never reach the lab (`lab/README.md`, "Initialization without a snapshot"): `refused`, `Result.Ran` empty, no subscription exists afterwards.
  - `TestLabApplyLockRefusesSecond`: a first apply of `create.yaml` held at its `Confirm` (the fake blocks on a channel); a second apply of the same file returns `refused` with the lock message; the first is then released and applies.
  - `TestLabApplyWaitZero`: `create.yaml` with `Wait` 0: every operation ran, `unconfirmed` outcome, exit code 3, the subscription's delivery `not_awaited`; a later apply of the same file after the delivery plans nothing.
  - `TestLabApplyResumesAfterFailure`: `create.yaml` with `BeforeStatement` returning an error before the `sp_addsubscription`: outcome `failed`, exit 1, the snapshot job of `m_p` enabled afterwards (R48), `Remaining` lists the rest; a second apply without the hook applies the remainder, delivered, converged.
  - `TestLabApplyInterruptRestores`: `create.yaml`, applied; `add-article.yaml` applied with `Interrupt` fed a `SIGINT` once the delivery wait has begun (the hook on the last statement starts a timer): outcome `unconfirmed`, exit 3, every snapshot job of `{db}` enabled, no `job left disabled` line.
  - `TestLabApplySnapshotAlreadyRunning`: `create.yaml`, applied; the test starts `m_p`'s snapshot (`sp_startpublication_snapshot`) right before applying `add-article.yaml`: applied, the output holds `waiting for the snapshot job of m_p to be idle`, delivered, converged.

- [ ] Step 1: Write the files and the eight tests.
- [ ] Step 2: Run, in one shell, `lab/gotest.sh '^TestLabApply' ./internal/convergence`. Expected: 8 `--- PASS`, the teardown check 0, and no `m_login_` login left.
- [ ] Step 3: Break step. Restore only on success: `TestLabApplyResumesAfterFailure` and `TestLabApplyInterruptRestores` fail on the job's enabled state. Restore. Treat every `LSNCheck` as valid: `TestLabApplyLSNRefused` fails in its hook, before any statement reaches the server. Restore.
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

- [ ] Step 1: `CLAUDE.md`: status (plan 4 done; `apply` exists; what plan 5 keeps, R42); architecture (`internal/apply`, the new `Checks`, the plan fields of Task 4); the traps found while building, each with its row or test; the rulings later sessions must not undo without a measurement (R45 to R52, R55 to R58, R61); replace "Before step 4" by "Before plan 5". `README.md`: `apply` complete. `lab/README.md`: the scripts of Tasks 1 to 3 and 13, and how the convergence tests now run through `apply`.
- [ ] Step 2: Run the whole suite on the lab, in one shell: `lab/gotest.sh '.' -timeout 60m ./...`. Expected: no `--- FAIL`, no `--- SKIP`; report the count. Then `go build ./cmd/sqlrepl && go vet ./... && test -z "$(gofmt -l .)" && go test ./...`. Check that nothing is left: no `m_` database, job, login, publication or profile, `MSreplservers` with its five rows.
- [ ] Step 3: Break step. Run `SQLREPL_TEST_LAB=1 go test -count=1 -v -run '^TestLabAppLock$' ./internal/apply` without the DSN: it fails, it does not skip.
- [ ] Step 4: Stop the lab (`SHUTDOWN WITH NOWAIT` through `sqlcmd`), report `podman ps`. Commit.

## What plan 5 receives

- `apply.Run` with its `Result`, the deliveries it confirms (`Delivery`), and its waits, which `sqlrepl snapshot` reuses for one publication; the R53 output lines, which the report extends rather than replaces.
- `Operation.Owes`, `OwesAt`, `Plan.OwedBefore`, `DistributionDB`, `SnapshotRoots`; the queries of `internal/apply/queries.go`.
- The rows of `20-apply`, `agent-stopped`, `21-deliveries` and `fresh-apply`.
- Open: the report and `-sample-tail` (R42), `-rotate-secret`, the windowed test of a generated and undelivered snapshot for `plan`, campaign items 15 to 18, the named instance, the remote distributor (R17), the 2019 and 2025 replays (R18), and the spec's line 119 on dropping another database's unused profile.

## Self-review

- Spec coverage. "apply" step 1 (R44, Task 9 `Target.Plan`), step 2 (R44, Tasks 9 and 10), step 3 (R46 pinned connections, R48 disable, idle wait and restore on every way out, R45 lock, R55 permission, R52 budget), step 4 (R46, R47), step 5 (R49, R50, R51, R52), the failure paragraph (R52, R53, Task 12 `TestLabApplyResumesAfterFailure`), 1205 and 18752 (R47). "Deliveries owed" (R50, Tasks 3, 4, 8). The deferral's generate and wait (R51, Task 4, Task 11 `TestLabDeferFullSnapshot`). "Secrets" for apply (R46, R54, Tasks 6 and 12). "Subscriptions", the LSN check (R57, Tasks 1, 5, 12). "Testing", the central scenario (Task 13) and the scenarios through apply (Task 11). "The report" and `-rotate-secret`: plan 5 (R42).
- Unmeasured inputs found while writing, each given a measurement before its consumer: the msdb roles and the disabled schedule and the LSN bounds (Task 1, consumed by Tasks 5 and 12), Agent stopped (Task 2, Tasks 5 and 6), the pull line, the in-place rewrite, the run in progress, the `S7` folder and the shared re-add (Task 3, Task 8). The application lock's behavior is tested directly (Task 6), since no outcome would change R45 but its failure.
- Type consistency: `plan.Statement`, `StatementSecret` (plan 3) used by `session.exec` and `secretArgs`; `plan.JobIdle` exported in Task 4, used by Tasks 2 and 7; `Operation.Owes`, `OwesAt`, `Plan.OwedBefore`, `DistributionDB`, `SnapshotRoots` produced by Task 4 and consumed by Task 8; `state.JobPermissionCheck`, `AgentServiceCheck`, `LSNCheck`, `SchemaCheck` produced by Task 5 and consumed by `plan` in Task 5 and by `Run`'s refusals in Task 9 through `Plan.Preconditions`; `precheck.Run`'s new `current` argument updated in the CLI and the harness in Task 5; `apply.Servers`, `Target`, `Options`, `Result`, `Outcome`, `Delivery` produced by Tasks 6, 8 and 9 and consumed by Tasks 10 to 12.
- Test counts per task: Task 1 `TOTAL|20`; Task 2 `TOTAL|9`, then 1 lab; Task 3 `TOTAL|5`; Task 4: 10 and 1; Task 5: 5, 1 and 3, then 3 lab; Task 6: 4, then 4 lab; Task 7: 2, then 3 lab; Task 8: 5, then 1 lab; Task 9: 4; Task 10: 5, then 3 lab; Task 11: 18 lab; Task 12: 8 lab; Task 13 `TOTAL|4` and 1 lab.
- Proportion: signatures, rulings with their sources, test names and assertions; no function body. The only exact text is the question, the output templates and the exit code table, which the tests pin.
