# sqlrepl plan 3: the planner Implementation Plan

> For agentic workers: REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

Goal: `sqlrepl plan -f desired.yaml` reads the current state, normalizes the desired file, compares the two, and prints the ordered operations, their exact T-SQL and the cost of each, refusing every change whose cost is not measured.

Architecture: three pure packages and one reader. `internal/normalize` turns a loaded file into the configuration it means (defaults by context, prerequisites, names, refusals). `internal/cost` holds the measured cost table and the flag rule, each entry citing the result rows it comes from, and a test reads those rows. `internal/plan` predicts the runtime state operation by operation, compares, applies the strategies of the spec, orders, renders T-SQL, a summary and JSON; it never imports `database/sql`. `internal/precheck` runs the read-only precondition checks. The CLI only parses flags, connects, calls `reader.Read`, `precheck.Run` and `plan.Build`, and prints.

Tech Stack: Go 1.26.5 (existing module, no new dependency), T-SQL, the lab container `repllab` (SQL Server 2022 CU27 Developer), bash for the measurement scripts.

Spec: `docs/superpowers/specs/2026-11-10-sqlrepl-plan-apply-design.md`. This plan implements "plan" (Inputs, What a plan is, Costs and unmeasured changes, Strategies, Order), "The file" (omitted properties, what is not compared, names), "Shared distributor objects", "Secrets" as far as `plan` needs them (loading, names in T-SQL, set or not), "Servers and connections", "Engine as a library", the two `plan` warnings of "Blocking", and the parts of "Measurement campaign" item 19 and 20 the planner cannot do without. Background: `CLAUDE.md`, `docs/analysis/step-1-analysis.md` sections 5 and 6, `lab/README.md` (rows 9 to 12, "Observed outside the campaign"), `lab/results/2022/`. House style and input contract: `docs/superpowers/plans/2026-11-11-sqlrepl-2-model-and-export.md`, "What plan 3 receives".

This is the third of four plans. Plan 4 keeps these spec sections: "apply" (all of it: confirmation, pinned connections, the snapshot job disable and restore and their `sp_update_job` / `sp_start_job` operations, the msdb permission precondition, the application lock, `@@TRANCOUNT` rollback, the retry on 21854 and 21861, 1205 and 18752, `-wait` as a budget, exit codes), "Deliveries owed", "Snapshot runs and their report" (except the two warnings of "Blocking" that `plan` prints), `apply -rotate-secret` and the execution of secrets through `sp_executesql`, the "Testing" central scenario from an instance with no replication, the replays on 2019 and 2025, and campaign items 14 to 18 and the rest of 19 and 20.

## Global Constraints

- Everything written in the repository (code, comments, docs, commit messages, results) is in English. The copied `internal/dotenv` has French comments: translate them.
- Documents: no bold, no em dash or en dash, titles that announce their subject without a conclusion or a count.
- Commit messages: a subject, a blank line, a prose body that says why; no `Co-Authored-By`, `Claude-Session`, `Generated with` or any other attribution trailer. Stage explicit paths, never `git add -A` or `.`.
- No new Go dependency. `go build ./cmd/sqlrepl`, `go vet ./...`, `test -z "$(gofmt -l .)"` and `go test ./...` without a DSN pass at the end of every task.
- `internal/normalize`, `internal/cost` and `internal/plan` import neither `database/sql` nor `internal/reader` nor `internal/precheck` (spec "Engine as a library"); `TestPurePackages` (Task 10) enforces it.
- Unknown values are never dropped (`CLAUDE.md`). In a desired file, an `unknown(n)` value is refused by normalization, since the engine cannot create what it cannot name.
- Server names and subscriber database names are compared without regard to case; publication, article, profile and schedule names exactly (Ruling R7).
- `plan` runs only `SELECT` statements and read-only checks. Every precheck query is added to `TestPrecheckQueriesParse`.
- Only measured entries exist (spec "Costs and unmeasured changes"). A change that no cost entry covers is refused with `cost of <change> not measured`, never guessed. Where a measurement contradicts this plan or the spec, stop and report what was measured; do not make the code agree with the document.
- Secret values never appear in any output, log or test failure message.
- Lab tests need `SQLREPL_TEST_DSN` and `SQLREPL_TEST_LAB=1` and run through `lab/gotest.sh` in one shell invocation that loads the password:

  ```
  set -a; . ~/Sources/Repos/atelier/livres-informatiques/optimiser-sql-server/edition-2026/harnais/.env; set +a
  lab/gotest.sh '<anchored filter>' ./internal/convergence
  ```

  The password is passed only by variable name (`SQLCMDPASSWORD`, `MSSQL_SA_PASSWORD`), never printed, never `-P`, never `bash -x`.
- Every test step names its `-run` filter, anchored, and the exact number of `--- PASS` lines, with no `--- SKIP` and no `--- FAIL`. Any other number, larger included, means the filter or the work is wrong.
- Every task has a break step: break the code as it says, run the named test, see it fail, restore. "One failed, the others passed" is the success of that step.
- Lab: container `repllab` on `127.0.0.1:11980`, started by `lab/start.sh 2022` when `podman ps` does not show it. Tests and scripts create only objects named `m_` (databases, tables, publications, profiles, servers), remove them in `t.Cleanup` or the script's cleanup even on failure, and touch the lab's own objects (`Sales`, `SalesSub`, `SalesPub`, `SalesRef`, `lab-distrib`) only by reading. SQL Server is stopped with `SHUTDOWN WITH NOWAIT`. No other container is touched.

## Review Focus

1. A file exported from a server and planned at once, unchanged: the most common use, and the one a normalization error turns into a reinitialization at every `apply` (spec "Costs"). Pinned by `TestBuildExportIsEmpty` (Task 15, on the lab fixture) and `TestLabSalesPlanEmpty` (Task 19, live, read-only).
2. Subscriber names in another case in the file, in `-server` and in `syssubscriptions` (`REPLLAB`, `repllab`): the subscription must match, not be dropped and re-added. Pinned by `TestDiffMatchesSubscriptionsIgnoringCase` (Task 10).
3. Object names with `'`, `]` and spaces in generated T-SQL (`a'b`, `x]y`, `m sub`): every literal and identifier quoted. Pinned by `TestRenderQuotesNames` (Task 16).
4. A current value the login could not read (an `unreadable` finding): it must not read as a change to plan. Pinned by `TestDiffSkipsUnreadable` (Task 10).
5. A second `plan` after a partly applied one (a subscription missing an article on a `concurrent` publication, a publication without its snapshot agent): it completes the intermediate state, never drops and re-adds. Pinned by `TestCompleteIntermediateSubscription` (Task 12) and `TestBuildRepairsIncomplete` (Task 15).

## Rulings made in this plan

Each is a decision the spec leaves to the builder, or a place where the spec and the measurements leave a choice. Reason and cost if wrong are given once, here.

- R1 Package layout. `internal/normalize` (defaults table, `Normalize`), `internal/cost` (cost table, flag rule), `internal/plan` (plan types, calls, state prediction, diff, strategies, order, rendering), `internal/precheck` (read-only checks), `internal/dotenv` (copied loader), `internal/convergence` (lab tests only). The pure data that crosses from the readers to the planner lives in `internal/state` (`Facts`, and the new `Checks`). Reason: spec "Engine as a library"; `state` is already the pure leaf both sides import. Cost if wrong: a package move.
- R2 One operation is one procedure call. A publication whose three properties change gives three `sp_changepublication` operations. Reason: `sp_change*` takes one property per call, the flags are per call, and apply logs and checks per statement. Cost: longer plans.
- R3 Any refusal refuses the whole plan, and every refusal is listed at once; a refused plan has no operations. Reason: the order and the predicted state of the rest depend on what is refused. Cost: the user fixes all refusals before seeing any operation.
- R4 A file without a `distributor` section means "the distributor in place, not compared"; when none exists, the plan is refused ("the file must declare the distributor to create"). Reason: the distributor is shared, and a short file must not reset other databases' retention to the procedure defaults. Cost: a reset to defaults must be written out.
- R5 A shared distribution agent or shared pull agent absent from the file is not compared. Its existence is never compared (spec "What is not compared").
- R6 Agent profiles. A profile in the file is created or changed; a profile absent from the file is dropped only when no row of `Facts.ProfileUses` names it, compared on `agent_type` and name, `virtual` rows included (ledger, Task 11 of plan 2). Lab tests copy the lab's `agent_profiles` into their files, so `lab-distrib` is never dropped.
- R7 Matching. Publications, articles, profiles and schedules by exact name; subscriptions and shared agents by subscriber and database, both case-insensitive (as `model.Load` and the reader do). Two desired publications whose names are equal without regard to case are refused: they collide in `distribution.dbo.MSpublications` (ledger, final review of plan 2).
- R8 Cost entries are keyed by the property's model path pattern, the publication type, and, for a boolean, the direction (`to_true`, `to_false`); for a nullable string, `set` or `clear`; for `sync_method`, the pair `<from>><to>`; for other values, any value to any other. Reason: the matrix measured one value per property; booleans and clears are measured both ways by Task 1, other values change what the call stores, not what it invalidates. Cost if wrong: a value-specific flag, which the server refuses (the next `plan` recomputes; `apply` stops).
- R9 The flag rule (`05-snapshot-flag`, analysis section 5, `CLAUDE.md`): `@force_invalidate_snapshot = 1` exactly when the predicted `immediate_sync_ready` is 1 and the entry's class touches the snapshot; `@force_reinit_subscription = 1` exactly when the class needs a reinitialization and some subscription row of the operated article (of any article for a publication-wide entry, `sync_method`) is predicted at publisher status 2. A flag is passed as `= 1` when needed and not passed otherwise. Status is `syssubscriptions.status` (`state.SubscriptionRow.PublisherStatus`).
- R10 State prediction (spec "Strategies"). After each operation, in plan order: a call that passed `@force_invalidate_snapshot = 1` leaves `ready` false (`15-snapshot-scope` `C.*`: `in_tran:ready=0`); `immediate_sync` false and `allow_anonymous` false leave `ready` false (`B.*.1a`, `B.*.1b`); `immediate_sync` true leaves it false (`B.*.4a`); `sp_addarticle` on an `immediate_sync` publication adds a status 1 row to every subscription (`C.*.addarticle`); an extension adds status 1 rows (`D.non_native.extend_rule`); a reinit-flagged call sets the operated article's rows, or every row for `sync_method`, to 1 (`C.*.schema_option`, `C.native.sync_method`); `sp_addsubscription` adds rows at 2 when the publication has `immediate_sync` and `ready` (`05-snapshot-flag` `S7`), at 1 otherwise (`11-defaults` `D.sp_addsubscription.push.@status`); the drop of a database's last publication removes its log reader (`13-transient` `T02`); "generate and wait" sets every row of the publication to 2.
- R11 A change of class `snapshot` (snapshot flag only, never the reinit flag) marks nothing: its cost is "full generation deferred" when `ready` and the publication keeps `immediate_sync`, online otherwise. Reason: measured for `alt_snapshot_folder` and `droparticle` (`C.*`); the other snapshot-only properties need no reinit flag, so the server marks no subscription. Cost if wrong: a cost line that understates, never a failed call.
- R12 A snapshot is pending for a publication when a subscription row is at publisher status 1, or, on a publication without `immediate_sync`, when a subscribed article is inactive. On an `immediate_sync` publication `sp_addarticle` sets the active bit at once, so only status 1 signals (ledger, plan 2 Task 11).
- R13 Agent state, from `state.AgentFacts` and the publication's `last_generation`: `unknown` when the job is nil or does not exist; `retrying` when the last history row has runstatus 5; `failed` when `last_failure` is at or after `last_generation` and the last history row has runstatus 6; `running` when the job runs; `stopped` otherwise. A runstatus 5 row is never a failure, and a running job that waits for its retry is `retrying`, not `running` (ledger, plan 2 Task 11).
- R14 Schema option `identity_property` (0x04) is not compared on an article whose current or desired `identity_range_management` is `manual`: `sp_addarticle` with `manual` adds it (ledger, plan 2 Task 12), and the reader reads `manual` from the table's `NOT FOR REPLICATION` identity. `identity_range_management` omitted means the current value for an existing article and is not passed at creation; a declared change of it is refused as unmeasured. Cost if wrong: a deliberate change of 0x04 on such an article is not planned.
- R15 A creation call passes a parameter only when its normalized value differs from the default of its context (Task 5), plus the identity parameters, plus the parameters the spec says to always pass (`@subscription_type = N'pull'` at both ends, `sp_addpullsubscription @independent_agent` and `@immediate_sync` from the publication, command procedures schema-qualified). A parameter whose `model.Parameters` `Since` is later than `2022` is never passed. Reason: a parameter not passed takes exactly the measured default; passing every parameter risks combinations no row measured. Cost if wrong: a non-converging property, which the convergence tests see.
- R16 Secrets in T-SQL. A secret parameter is rendered `@<param> = @secret_<n>`, numbered in plan order, and the statement is preceded by the comment `-- @secret_<n>: secret <NAME>`. Plan 4 passes `@secret_<n>` as a driver parameter, so the printed text is the executed text without the value (spec "Secrets"). `plan` reports each secret as set or not set; it never reads a value beyond `os.LookupEnv`'s presence, and never refuses for a missing one.
- R17 The distributor is created only locally (the distributor is the publisher instance), from `distributor-defaults`, the only measured setup. A plan that needs a remote distributor registered or created is refused: "remote distributor setup not measured (distributor-defaults ran on a local distributor only)". The local creation is unit-tested here; its live test needs a fresh container and is plan 4's central scenario. Cost: remote setups wait for a measurement on the Windows lab VMs.
- R18 Version. `plan` refuses any publisher, distributor or subscriber whose major version is not 16: "the cost table holds measurements of SQL Server 2022 (16.x) only; <name> runs <version>" (spec "Scope": the support claim holds once the campaign has run there).
- R19 `sync_method` pairs. Transactional: `native>concurrent`, `concurrent>native`, `concurrent_c>native`, `concurrent>concurrent_c`, `concurrent_c>concurrent` (reinit class, publication-wide), `native>character`, `character>native`, `database_snapshot>native` (snapshot class). Snapshot publications: `native>character`, `native>database_snapshot` (snapshot class); a change to `concurrent` or `concurrent_c` refused with 22547. Every other pair is refused as not measured, `native>concurrent_c` and `character>concurrent` included. Reason: the spec's "Any other pair is refused" read strictly, by "Only measured entries exist". Cost: a direct change across families takes two plans through `native`.
- R20 An article whose `type` family (table, schema only, procedure execution) or `source` changes is dropped and added back under the drop and add rules (`06-structural` `C3`). `proc_exec` and `serializable_proc_exec` articles have no measured defaults or costs: creating one or changing one is refused; an unchanged one plans nothing.
- R21 Subscriptions. A change of `type` (push and pull) is refused ("drop it in one plan and add it in another"). A pull subscription to a publication without `independent_agent` is refused (its shared pull agent is not measured, plan 2 "Open after this plan"). A change of `initialization` alone plans nothing and notes it (spec). Creating a subscription with `initialization: lsn` is refused until the LSN check of spec "Subscriptions" exists (`10-init-modes` `I3.lsn.create` showed the formula wrong); `backup` and `replication_support_only` are allowed.
- R22 Schedules are compared without their name (replication generates it); an agent with more than one schedule in the file is refused. An omitted schedule is the procedure's, compared on its frequency fields only (`frequency`, `interval`, `subday`, `subday_interval`); a declared one in full. Only the snapshot agent's schedule can change: one `sp_changepublication_snapshot` call passing every `@frequency_*` and `@active_*` parameter of the declared schedule (`07-changes` `AGT.sp_changepublication_snapshot.*`: `frequency_type` alone is refused with 14278). A schedule change of any other agent is refused as not measured.
- R23 `job_enabled` omitted is true for a snapshot agent (spec "apply" step 3) and not compared for other agents (no measured default). A difference is one `msdb.dbo.sp_update_job @job_name, @enabled` at the job's server, cost online, source `lab/README.md` `O20`.
- R24 `plan` emits no snapshot job disable or restore and no `sp_start_job`: they are `apply`'s, with their exit semantics (plan 4). `plan` lists the agents `apply` will start (snapshot agents of publications predicted pending at the end, and the distribution agents of the subscriptions they serve).
- R25 The "generate and wait" step of `-defer-full-snapshot` is an operation of kind `generate_and_wait` whose call is `sp_startpublication_snapshot @publication`; the wait for its deliveries is plan 4's.
- R26 Findings of the current configuration. Any `out_of_scope` finding refuses the database, one refusal per finding. An `unreadable` finding excludes its path and everything under it from the comparison, with a note. An `incomplete` finding is repaired only by the rules listed in Task 15 (snapshot agent, log reader, subset subscription, filter clause without procedure, filter procedure without clause, synchronization view out of step); any other is refused with its message: "repair of this state is not measured".
- R27 A file with no publication for a database that is published plans no `sp_replicationdboption @value = N'false'`: unpublishing is not in the spec's order. The publications are dropped; the database stays enabled.
- R28 Output. The summary is printed unless `-json`; `-sql` appends the T-SQL after it; `-json` prints the plan as JSON only. Exit 1 on an error or a refusal (the refusals printed first), 0 otherwise, empty plan included.
- R29 Connections. A server of the file is reached at its `-server NAME=ADDRESS` address, otherwise at its name. A subscriber that cannot be reached makes its preconditions `unchecked`, refuses every operation that runs there (pull), and leaves push operations planned with the `unchecked` precondition listed. The publisher and the distributor must be reached.
- R30 Columns. `columns` omitted, `[]`, and the full column list of the table (from `state.Checks.Tables`) are the same value. When the table's columns were not read, the lists are compared as given.
- R31 Desired `sync_object` nil means the generated view; a desired nil against a current user view is refused ("returning to a generated view is not measured"). A user view's definition is never compared (plan 2 parked: a hand-altered unbracketed view counts as the user's own).
- R32 The command line (`command`) is not compared. `plan` warns when it holds a switch outside the set the procedures write, the switches of the lab fixture's commands per agent kind (`internal/testdata/lab/sales.yaml`), listed in code with that source.
- R33 Lab tests use their own publication databases (`m_pdb_<test>`) and subscriber databases (`m_sdb_<test>`), never `Sales`: the file is the whole truth for its database, and a test file for `Sales` would drop `SalesPub`.

## Ledger items of plan 2 and where they are folded

| Ledger line (`.superpowers/sdd/2026-11-11-sqlrepl-2-model-and-export/progress.md`) | Folded into |
|---|---|
| For plan 3: on `immediate_sync`, `sp_addarticle` sets the active bit at once, only publisher status 1 signals pending | R12, Task 9 `TestPendingDefinition` |
| For plan 3: runstatus 5 is not a failure; `job.running` while a failed agent waits for its retry | R13, Task 9 `TestAgentStatus` |
| For plan 3: applying `manual` adds schema option 0x04 | R14, Task 6 `TestNormalizeIdentityBit` |
| For plan 3/4: `sp_droppullsubscription` leaves a shared pull agent's job behind | Task 12 `TestDropLastPullOfSharedAgentWarns` (cost "subscriber object left behind"); the job delete stays with plan 4 |
| For plan 4: dropping a publication deletes an Agent proxy set on its snapshot job step | Task 11 warning on publication drop when `run_as` is not empty (`TestDropPublicationProxyWarning`); the rest is plan 4's |
| Ruling: publications differing only by case collide in `MSpublications` | R7, Task 6 `TestNormalizePublicationNameCollision` |
| Ruling: enumerations are not validated in `Load`, plan 3's normalization does it | Task 6 `TestNormalizeEnumerations` |
| Parked: `profile_uses` subscriber case | R6, Task 14 `TestProfileDropOnlyUnused` |
| Parked: an unused `-server` name | Task 18: a note on stderr, `TestPlanUnusedServerNote` |
| Parked (Task 5): a zero `Source.Probe` gives "database is "; `Start` runs twice | Task 4: `Read` refuses a zero probe (`TestReadRefusesZeroProbe`); the CLI always probes (Task 18) |
| Parked (Task 5): `-distributor` given while the probe finds none opens it anyway | Task 18: `plan` has no `-distributor`; the distributor is the file's or the probe's |
| Ruling (Task 3): empty slices after a round trip | R30 and Task 10 `TestDiffNilAndEmptyLists` |
| Ruling (Task 12): non-pointer fields outside `NilProperties` | Task 10: the diff compares the non-pointer fields explicitly (`Schedule` fields, `Columns`, `Articles`, `Filter.Clause`, `Command.Mode`) |
| Parked (Task 8): an unbracketed hand-altered view is the user's own | R31 |
| Parked (Task 12): a NOT FOR REPLICATION identity reads `manual`; the `auto` branch is untested | R14; `auto` is `out_of_scope`, refused by R26 |
| Parked (Task 13): 2025 encryption keys unmeasured | R18 refuses 2025; `link_*` changes have no cost entry |
| Parked (Task 11): `MSrepl_errors` tie-break; (Task 7) a glued password switch not masked | Not folded: neither changes a plan (the message shown, a command never compared) |

---

### Task 1: Reverse directions of the measured properties

Files:
- Create: `lab/campaign/18-reverse.sh`, `lab/results/2022/18-reverse.txt`
- Modify: `lab/README.md` (section "Reverse directions", row in "Planned and measured totals")

Interfaces:
- Produces: rows `R|RV.<state>.<case>|f00=..,f10=..,f01=..,f11=..|<label> (ready=<n> status=<n>)` and `R|RV.<state>.state|ready=<n> status=<n>|`, read by `TestCostTableMatchesRows` (Task 7).

- [ ] Step 1: Write `lab/campaign/18-reverse.sh` on the model of `05-snapshot-flag.sh` (its helpers in `lab/lib.sh`, its state building, its four-cell flag runs, each in a rolled-back transaction). In `Sales`, tables `dbo.m_rv_t1 (id int PRIMARY KEY, a int, b int)` with 10 rows; subscriber database `m_rv_sub`. Three publications, each with a snapshot agent on the never-firing schedule (`@frequency_type = 1, @active_start_date = 99991231`):
  - state `I`: `m_rv_i`, `@independent_agent = N'true'`, `@immediate_sync = N'true'`, `@sync_method = N'native'`, created with the non-default values `@replicate_ddl = 0`, `@allow_pull = N'true'`, `@allow_initialize_from_backup = N'true'`, `@allow_subscription_copy = N'true'`, `@allow_partition_switch = N'true'`, `@replicate_partition_switch = N'true'`, `@alt_snapshot_folder = N'/var/opt/mssql/data/ReplAlt'`, `@snapshot_in_defaultfolder = N'false'`, `@pre_snapshot_script` and `@post_snapshot_script` set to existing files under `/var/opt/mssql/data`, and `sp_changepublication allow_drop true` before the article; article `m_rv_t1` with `@status = 8` (column names, not parameterized), `@fire_triggers_on_snapshot = N'true'`, `@creation_script` set; a push subscription to `m_rv_sub`, snapshot started and delivered (state of `05` `S1`: ready 1, status 2).
  - state `N`: `m_rv_n`, the same without `immediate_sync`, `independent_agent` or `allow_subscription_copy` (21210), subscribed and delivered (ready 0, status 2).
  - state `P`: `m_rv_p`, no `immediate_sync`, `@allow_push = N'false'`, `@allow_pull = N'true'`, `@status = N'inactive'`, no subscription.

  Cases, each run with the four flag combinations, case ids in parentheses: in `I` and `N`: `replicate_ddl = 1` (`replicate_ddl`); `allow_pull = false` (`allow_pull`); `allow_initialize_from_backup = false` (`allow_initialize_from_backup`); `allow_subscription_copy = false` (`allow_subscription_copy`, `I` only); `replicate_partition_switch = false` (`replicate_partition_switch`); prep `replicate_partition_switch = false` with both flags 0 in the same transaction, then `true` (`replicate_partition_switch_true`); prep the same, then `allow_partition_switch = false` (`allow_partition_switch`); `allow_drop = false` (`allow_drop`); `snapshot_in_defaultfolder = true` (`snapshot_in_defaultfolder`); `alt_snapshot_folder` with `@value = NULL` (`alt_snapshot_folder.null`) and `N''` (`alt_snapshot_folder.empty`); the same two for `pre_snapshot_script` and `post_snapshot_script` (`pre_snapshot_script.null` and so on); article `fire_triggers_on_snapshot = false` (`fire_triggers_on_snapshot`); article `status = no column names` (`status.no_column_names`); article `status = parameters` (`status.parameters`); article `creation_script` NULL and `N''` (`creation_script.null`, `creation_script.empty`). In `P`: `status = active` (`status`); `allow_push = true` (`allow_push`). The label names the procedure, property and value, as `02-matrix` does. Then one `state` row per state. Cleanup drops the subscriptions, publications, `m_rv_sub` and the table even after a failure.
- [ ] Step 2: Run it, in one shell: load the password, `lab/campaign.sh 2022 lab/campaign/18-reverse.sh`. Expected: exit 0, every guard passing, `R|TOTAL|44` (20 cases in `I`, 19 in `N`, 2 in `P`, 3 state rows). Another count is reported, not reconciled. Every case row has four cells.
- [ ] Step 3: Break step. Make the cleanup skip the drop of `m_rv_p`. Expected: `GUARD residue failed`. Restore, rerun, the same total.
- [ ] Step 4: Add the `lab/README.md` section (what each state is, the cases, which results surprised) and the row `18-reverse` (planned 44, measured n). Commit the script, the results and the README.

### Task 2: Destination owner, subscriber type and snapshot agent defaults

Files:
- Modify: `lab/campaign/11-defaults.sh`, `lab/results/2022/11-defaults.txt`, `lab/README.md`

Interfaces:
- Produces: new rows of `11-defaults.txt`, read by `TestDefaultsCiteRows` (Task 5):
  - `D.sp_addarticle.<kind>.nondbo.<method>.@<param>` for `<kind>` in `table`, `view-schema-only`, `proc-schema-only`, `func-schema-only` and `<method>` in `native`, `character`, `concurrent`, `concurrent_c`, `dbsnap`, `dbsnap_c`, on a transactional publication, the source in schema `m_s` (spec campaign item 20, `O16`);
  - `D.sp_addarticle.<kind>.nondbo.snapshot-pub.<method>.@<param>` for the same kinds and `native`, `character`, `dbsnap`, `dbsnap_c`;
  - `D.sp_addpublication_snapshot.snapshot-pub.@<param>` (the snapshot agent of a snapshot publication);
  - `D.sp_addsubscription.push.fresh-subscriber.@subscriber_type` (spec item 19: one push subscription to a subscriber name `m_freshsub` not registered before the call; cleanup `sp_dropsubscription`, then `sp_dropsubscriber @subscriber = N'm_freshsub'`).

- [ ] Step 1: Add the contexts the way the script defines `table.non-dbo-schema` (its `article` and `expect` lines, line 562 onward), with one publication per method (`m_pa_<method>`, transactional; `m_ps_<method>`, snapshot), each article's source an object of `m_s` (`m_s.m_t`, a view, a procedure and a function of `m_s`). Each context reads the parameters the script already reads for its article type. If `sp_addsubscription` to `m_freshsub` is refused, the row records the error number as its result: do not work around it.
- [ ] Step 2: Run, in one shell: `lab/campaign.sh 2022 lab/campaign/11-defaults.sh`. Expected: exit 0, every guard passing. `git diff lab/results/2022/11-defaults.txt` shows only added rows (the fields documented as varying in `lab/README.md`, "Reading the results files", excepted, and the `TOTAL` line). Report the new total. Expected values, from `O16` and the spec's defaults table, to be confirmed, not imposed: `@destination_owner` `m_s` under `native`, `concurrent` and `dbsnap`, `null` under `character` and `concurrent_c`, for every kind.
- [ ] Step 3: Break step. Remove the cleanup of `m_freshsub`. Expected: `GUARD residue failed` (an `m_` linked server or subscriber left). Restore, rerun.
- [ ] Step 4: Update `lab/README.md` ("Defaults and execution contexts": the new contexts and what they showed; turn `O16` into a citation of these rows; the subscriber type result; the total in "Planned and measured totals"). Commit.

### Task 3: Agent profile changes

Files:
- Create: `lab/campaign/19-profiles.sql`, `lab/results/2022/19-profiles.txt`
- Modify: `lab/README.md`

Interfaces:
- Produces: rows `R|PF.<case>|ok or <error>|<what changed in msdb.dbo.MSagent_profiles and MSagent_parameters>`, read by Task 7.

- [ ] Step 1: Write the script, run from `master`, each case in its own transaction rolled back, on a distribution profile `m_prof` created inside it with `sp_add_agent_profile @profile_name = N'm_prof', @agent_type = 3, @profile_type = 1` and one parameter `-CommitBatchSize 100` (`sp_add_agent_parameter`). Cases: `PF.change_description` (`sp_change_agent_profile @property = N'description'`), `PF.change_parameter` (`sp_change_agent_parameter`, `-CommitBatchSize` to `200`), `PF.add_parameter` (`-QueryTimeout 600`), `PF.drop_parameter` (`sp_drop_agent_parameter`), `PF.set_default` (the procedure and property the 2019 sources in `stored-procedures/sp_change_agent_profile.sql` use to make a profile the default of its type; read the source and name them in the label), `PF.drop_unused` (`sp_drop_agent_profile`). Each row reads back the changed column. Format of `01-articles.sql`.
- [ ] Step 2: Run, in one shell: `lab/campaign.sh 2022 lab/campaign/19-profiles.sql`. Expected: exit 0, `R|TOTAL|6`.
- [ ] Step 3: Break step. Replace one `ROLLBACK` by `COMMIT`. Expected: `GUARD residue failed` (profile `m_prof` left). Restore, delete `m_prof` by hand if it was left, rerun.
- [ ] Step 4: `lab/README.md` section and totals row. Commit.

### Task 4: Reader and model additions the planner needs

Files:
- Create: `internal/model/rules.go`, `internal/model/rules_test.go`, `internal/testdata/lab/sales.yaml`, `internal/testdata/lab/sales-facts.json`
- Modify: `internal/reader/syncview.go`, `internal/reader/publisher.go`, `internal/reader/reader_test.go`, `internal/reader/reader.go`, `internal/reader/facts.go`, `internal/reader/queries.go`, `internal/reader/lab_test.go`, `internal/state/facts.go`, `internal/state/facts_test.go`

Interfaces:
- Produces:
  - `func (p *Publication) SubsetAllowed() bool` in `internal/model` (moved from the reader's `subsetAllowed`, same rule: false with `immediate_sync` true or `sync_method` `concurrent` or `concurrent_c`); the reader calls it.
  - `state.Facts.PublisherDatabases []PublisherDatabase` (`json:"publisher_databases"`), `type PublisherDatabase struct { DistributionDB, Publisher, Database string }` (`distribution_db`, `publisher`, `database`): every row of `MSpublisher_databases` of every distribution database of the distributor, the publisher name through that database's own servers table, as `ProfileUses` does. Read only when `Source.Facts`. `func publisherDatabasesQuery(dbs []string, useFallback bool) string`, built like `profileUsesQuery`.
  - `Read` returns the error `reader: Source.Probe is not set` when `src.Probe.State == ""`, before any query.
  - The lab fixture: `internal/testdata/lab/sales.yaml` and `sales-facts.json`, the export of `Sales` with `-facts`, captured by Step 4. Every later unit test that needs a realistic configuration loads these two files.

- [ ] Step 1: Write the tests. `TestPublicationSubsetAllowed` (`internal/model`): the cases of the reader's `TestSubsetAllowed`, which moves here. `TestPublisherDatabasesQuery` (`internal/reader`): for `distribution` and `m dist]2` the query contains `[m dist]]2].dbo.MSpublisher_databases` and no `{`. `TestReadRefusesZeroProbe`: `Read(ctx, Source{})` returns that error and does not panic. `TestFactsJSONKeys` gains `publisher_databases` and its three keys. In `lab_test.go`, `TestReadLabFacts` gains: `publisher_databases` holds `{distribution, <lab @@SERVERNAME, any case>, Sales}`. `TestQueriesParse` gains `publisherDatabasesQuery` for two names, parse only.
- [ ] Step 2: Run `go test -count=1 -v -run '^TestPublicationSubsetAllowed$' ./internal/model` and `go test -count=1 -v -run '^(TestPublisherDatabasesQuery|TestReadRefusesZeroProbe)$' ./internal/reader`. Expected: compile failures.
- [ ] Step 3: Implement.
- [ ] Step 4: Run the Step 2 commands (1 and 2 `--- PASS`), `go test -count=1 -v -run '^TestFactsJSONKeys$' ./internal/state` (1), then `lab/gotest.sh '^(TestReadLabFacts|TestQueriesParse)$' ./internal/reader` (2). Then, in one shell, build `sqlrepl` and write the fixture: `sqlrepl export -publisher 'tcp:127.0.0.1,11980' -distributor 'tcp:127.0.0.1,11980' -database Sales -user sa -param encrypt=disable -o internal/testdata/lab/sales.yaml -facts internal/testdata/lab/sales-facts.json`, with `SQLREPL_PASSWORD` from `MSSQL_SA_PASSWORD`. Check that neither file contains the password (`grep -c` of it by variable, 0) and that the YAML has no `findings:` key.
- [ ] Step 5: Break step. Make `SubsetAllowed` ignore `concurrent_c`: `TestPublicationSubsetAllowed` fails. Restore.
- [ ] Step 6: Commit.

### Task 5: Defaults table

Files:
- Create: `internal/normalize/defaults.go`, `internal/normalize/defaults_test.go`

Interfaces:
- Consumes: `lab/results/2022/11-defaults.txt` (Task 2 rows included), `lab/results/2022/distributor-defaults.txt`, `model.Parameters`, `decode`.
- Produces:

```go
type Context struct {
	Object      string // publication, article, subscription, snapshot_agent, push_agent, pull_subscription, pull_agent, log_reader_agent, distributor, distribution_db, distpublisher, profile
	PubType     string // transactional, snapshot, or "" for any
	SyncMethod  string // a decode name, or "" for any
	ArticleKind string // table, view_schema_only, proc_schema_only, func_schema_only, or ""
}

type Default struct {
	Context Context
	Path    string // relative pattern under the object: retention_hours, destination.schema, commands.insert
	Value   string // the model value; may hold {source_schema}, {source_name}, {schema}{table} templates; "" is NULL
	Row     string // "11-defaults D.sp_addpublication.transactional.@retention"
	Stored  string // the result field of that row, verbatim
}

var Defaults []Default

func Lookup(ctx Context, path string) (Default, bool) // the most specific entry: an exact SyncMethod and ArticleKind beat ""
```

- What it holds: one entry per row `D.<procedure>.<context>.@<param>` of the contexts below whose parameter `model.Parameters` maps as `field` to a path under the object, the row's result not `no-column`, `no-row`, `assigned` or `pre-existing(...)`. Contexts: `sp_addpublication.transactional` and `.snapshot`; `sp_addarticle` `table.native`, `table.concurrent`, `table.character`, `table.snapshot-pub`, and every `nondbo` context of Task 2 (which decide the destination owner of every source schema: a non-`dbo` source tells "the source schema" from `dbo`); `sp_addpublication_snapshot.transactional` and `.snapshot-pub`; `sp_addlogreader_agent.publication-db`; `sp_addsubscription.push` and `.pull`; `sp_addpushsubscription_agent.push`; `sp_addpullsubscription.pull`; `sp_addpullsubscription_agent.pull`; `sp_add_agent_profile.agent-type-3`; `distributor-defaults` `sp_adddistributor.fresh`, `sp_adddistributiondb.fresh`, `sp_adddistpublisher.fresh`. A row the implementer cannot express is listed in `var notDefaults = map[string]string{row: reason}`, never dropped silently.
- The value for `sp_addsubscription @subscriber_type` exists only if Task 2's row is a value; when it is an error, there is no entry and normalization refuses its omission (spec).

- [ ] Step 1: Write the tests. `TestDefaultsCiteRows`: every `Row` exists in its file and its result field equals `Stored`. `TestDefaultsCoverRows`: every row of the listed contexts that maps to a field has an entry or a `notDefaults` reason. `TestDefaultsDecodeStored`: for each entry, `Stored` decoded with the decoder of its path (`decode.SyncMethod` of `0` is `native`, `decode.SchemaOptionNames` of `0x0000000000030073`, the command parsed by `decode.ParseCommand`, `1` is `true`, `null` is `""`), with the row's object names put in the template (`dbo`, `m_t`, `m_s`), equals `Value`. `TestDefaultsSpecSample`, the spec's table: for `Context{article, transactional, native, table}`: `schema_options` the names of `0x30073`, `commands.insert` `CALL [dbo].[sp_MSins_{schema}{table}]`, `commands.update` `SCALL [dbo].[sp_MSupd_{schema}{table}]`, `destination.schema` `{source_schema}`, `parameterized` `true`, `insert_column_names` `false`, `pre_creation_cmd` `drop`; `character`: `commands.insert` `SQL`, `destination.schema` `""`; `snapshot`, `native`: `schema_options` the names of `0x30071`, commands `SQL`, `destination.schema` `{source_schema}`; `view_schema_only` `native`: `schema_options` `[object_creation]`; publication transactional: `sync_method` `native`, `retention_hours` `336`, `independent_agent` `false`, `immediate_sync` `false`, `allow_push` `true`, `allow_pull` `false`, `replicate_ddl` `true`, `status` `inactive`. `TestDefaultsLookup`: a `SyncMethod: "character"` entry beats a `""` one for `character`, and `Lookup` of an unknown context returns false.
- [ ] Step 2: Run `go test -count=1 -v -run '^(TestDefaultsCiteRows|TestDefaultsCoverRows|TestDefaultsDecodeStored|TestDefaultsSpecSample|TestDefaultsLookup)$' ./internal/normalize`. Expected: compile failure.
- [ ] Step 3: Write `Defaults`, `Lookup` and the test's row parser (`R|<id>|<result>|<detail>`; the files are read from `../../lab/results/2022/`).
- [ ] Step 4: Run the Step 2 command. Expected: 5 `--- PASS`.
- [ ] Step 5: Break step. Change the stored retention to `335`: `TestDefaultsCiteRows` fails. Restore. Delete the `@sync_method` entry of `sp_addpublication.transactional`: `TestDefaultsCoverRows` fails naming the row. Restore.
- [ ] Step 6: Commit.

### Task 6: Normalization

Files:
- Create: `internal/normalize/normalize.go`, `internal/normalize/normalize_test.go`

Interfaces:
- Consumes: `Defaults`, `Lookup` (Task 5); `model.Config`, `model.Publication.SubsetAllowed` (Task 4); `decode` `*Code` functions.
- Produces:

```go
type Refusal struct {
	Path   string `json:"path"`
	Reason string `json:"reason"`
}

// Normalize returns a deep copy of desired in which every omitted property
// holds the value it means, and the refusals. current may be nil.
func Normalize(desired, current *model.Config) (*model.Config, []Refusal)
```

- Rules, in this order; each refusal names the path and, where the server would refuse, its error number:
  1. Enumerations: every coded string goes through its `decode` inverse (`SyncMethodCode`, `PublicationTypeCode`, `PublicationStatusCode`, `ArticleTypeCode`, `PreCreationCmdCode`, `SecurityModeCode`, `SubscriptionTypeCode`, `SubscriberTypeCode`, `InitializationCode`, `FreqTypeCode`, `FreqSubdayTypeCode`, `EncodeSchemaOptions`, command modes); an error or an `unknown(...)` value is a refusal "unknown value %q". Desired `findings` are dropped.
  2. Required (spec "Omitted properties"): `publications[*].status`, `subscriptions[*].initialization`, and `filter.procedure` of a declared filter: refusal "%s has no default and must be written". `subscriber_type` too while Task 5 has no entry for it.
  3. Names: R7's publication collision; a command procedure without a schema gets `dbo` (spec "Names", `11-defaults` `D.sp_addarticle.table.non-dbo-schema.@ins_cmd`).
  4. Prerequisites before defaults (spec): `immediate_sync` true makes an omitted `independent_agent` true; `allow_anonymous` true makes an omitted `immediate_sync` true (then the previous rule); a pull subscription makes an omitted `allow_pull` true, a push one an omitted `allow_push` true; an omitted `replicate_partition_switch` takes `allow_partition_switch`'s value (plan 2 "Rulings", `0x60`).
  5. Defaults by context from `Lookup`, for every nil property of a declared object, the context taken from the normalized publication (`type`, `sync_method`) and the article (its type family, its source schema and name for the templates). An omitted `type` of an article is `logbased` for a table source; the source kind of an existing article comes from `current`; of a new one, from the file (the `type` must then be written for a non-table source: refusal otherwise). A nil property with no measured default is a refusal "default of %s for %s not measured" (the `dbsnap_c` and snapshot `concurrent` contexts among them).
  6. Omitted means current (R4, R14): the whole `distributor` section when omitted and `current.Distributor` exists; `data_folder`, `data_file`, `log_folder`, `log_file`, `working_directory` of an existing distributor; `identity_range_management` of an existing article. Omitted `schedules` keep nil, read by the diff as "the procedure's schedule, frequency fields only" (R22); `job_enabled` of a snapshot agent is true (R23); a command whose procedure is generated keeps a nil procedure, read by the diff as "generated, mode only".
  7. Conflicts, after defaults: `immediate_sync` true with `independent_agent` false (21022); `allow_anonymous` true without `immediate_sync` (20011); `allow_subscription_copy` true without `immediate_sync` (21210); `replicate_partition_switch` true with `allow_partition_switch` false (21866); `snapshot.compress` true without `alt_folder` (21157); `enabled_for_internet` true without `ftp.address` (21158); a subscription on a publication whose `status` is `inactive` (21000); a pull subscription with `allow_pull` false, a push one with `allow_push` false (20012); `sync_method` `concurrent` or `concurrent_c` on a snapshot publication (22547); a subscription with `articles` on a publication where `SubsetAllowed` is false (14100 or 14122); `enabled_for_het_sub` true and `identity_range_management` `auto` (out of scope, spec "Scope").
  8. R14: when the normalized or the current `identity_range_management` of an article is `manual`, `identity_property` is removed from its `schema_options` (and the diff removes it from the current side, Task 10).
  9. When `schema_options` holds `timestamp_as_timestamp`, `insert_column_names` is set to the current value (derived, spec "What is not compared", lab row 3).

- [ ] Step 1: Write the tests, each table-driven over small configurations built in Go with `model.Ptr`. `TestNormalizeFillsDefaults`: an article `A` of `dbo.T` on a transactional `native` publication with nothing but its name and source gets the `TestDefaultsSpecSample` values, the templates filled (`CALL [dbo].[sp_MSins_dboT]`, destination schema `dbo`); the same of `m_s.T` under `character` gets destination schema `""`. `TestNormalizeRequired`: a publication without `status`, a subscription without `initialization`, a filter without `procedure`: three refusals at `publications[P].status`, `publications[P].subscriptions[S/D].initialization`, `publications[P].articles[A].filter.procedure`. `TestNormalizePrerequisites`: `immediate_sync: true` alone gives `independent_agent` true and no refusal; `allow_anonymous: true` alone gives both; a pull subscription gives `allow_pull` true; `allow_partition_switch: true` gives `replicate_partition_switch` true. `TestNormalizeConflicts`: one case per conflict of rule 7, each refusal message containing its error number. `TestNormalizeEnumerations`: `sync_method: concurent` is refused at `publications[P].sync_method` with `unknown value "concurent"`; `type: unknown(9)` is refused. `TestNormalizeQualifiesCommands`: `CALL m_ins` becomes procedure `{dbo, m_ins}`; `CALL [s].[p]` keeps `s`. `TestNormalizePublicationNameCollision`: publications `P` and `p` give one refusal naming both. `TestNormalizeIdentityBit`: an article with `manual` and `schema_options` holding `identity_property` comes out without it. `TestNormalizeKeepsCurrent`: desired without `distributor` and a current one with retention 72 gives retention 72; a desired distributor without `data_folder` gets the current one. `TestNormalizeIdempotent`: `Normalize(Normalize(x))` deep-equals `Normalize(x)` for the fixture and for the short configurations above. `TestNormalizeExportUnchanged`: the fixture `internal/testdata/lab/sales.yaml` loaded with `model.Load` normalizes, against itself as current, with no refusal and deep-equal to itself except the `findings`.
- [ ] Step 2: Run `go test -count=1 -v -run '^TestNormalize' ./internal/normalize`. Expected: compile failure.
- [ ] Step 3: Implement `Normalize`.
- [ ] Step 4: Run the Step 2 command. Expected: 11 `--- PASS`. Then `go test ./...`.
- [ ] Step 5: Break step. Apply defaults before prerequisites (swap rules 4 and 5): `TestNormalizePrerequisites` fails (`independent_agent` takes the default false, then rule 7 refuses with 21022). Restore. Drop the `dbo` qualification: `TestNormalizeQualifiesCommands` fails. Restore.
- [ ] Step 6: Commit.

### Task 7: Cost table

Files:
- Create: `internal/cost/cost.go`, `internal/cost/table.go`, `internal/cost/cost_test.go`, `internal/cost/rows_test.go`

Interfaces:
- Consumes: `lab/results/2022/` (`02-matrix`, `05-snapshot-flag`, `06-structural`, `07-changes`, `08-pull`, `09-snapshot-pub`, `14-filter-view`, `15-snapshot-scope`, `18-reverse`, `19-profiles`), `lab/README.md` for `O` rows.
- Produces:

```go
type Class string

const (
	Online         Class = "online"          // no flag in any state
	Snapshot       Class = "snapshot"        // @force_invalidate_snapshot when ready
	SnapshotReinit Class = "snapshot_reinit" // and @force_reinit_subscription when a row is at 2
	DropsReady     Class = "drops_ready"     // no flag; a ready snapshot is dropped
	DropReadd      Class = "drop_readd"      // refused while subscriptions exist: drop and re-add them
	Refused        Class = "refused"         // the server refuses it in every combination
)

type Cite struct {
	Row   string // "02-matrix P21", "15-snapshot-scope C.native.sync_method", "lab/README.md O20"
	Ready bool   // immediate_sync_ready in the state the row measured
	At2   bool   // the operated rows were at status 2
}

type Entry struct {
	Change    string // a model path pattern, or an operation name (Operations below)
	Dir       string // "", to_true, to_false, set, clear, or "<from>><to>" (R8)
	PubType   string // transactional, snapshot, "" for both
	Procedure string // sp_changepublication; "" for an operation
	Property  string // the @property value: retention
	Class     Class
	Wide      bool   // the reinit condition looks at every row of the publication
	Error     int    // Refused, DropReadd: the server's error
	Cites     []Cite
}

type FlagState struct{ Ready, At2 bool }

var Table []Entry

func Lookup(change, dir, pubType string) (Entry, bool)
func Flags(e Entry, s FlagState) (invalidate, reinit bool) // R9
```

- Operation names used as `Change`: `add_article`, `drop_article`, `article_filter`, `article_view`, `article_column`, `add_subscription`, `extend_subscription`, `drop_subscription`, `drop_subscription_article`, `add_publication`, `drop_publication`, `profile_binding`, `job_enabled`, `generate_and_wait`.
- The table, transactional publications unless said otherwise (`02-matrix` SalesPub rows: ready, at 2; SalesRef: not ready, at 2; `RV.I`: ready, at 2; `RV.N`: not ready, at 2; `RV.P`: not ready, no row):

| Change | Dir | Procedure, property | Class | Cites |
|---|---|---|---|---|
| `publications[*].description` | | `sp_changepublication description` | online | `02-matrix P01`, `P02`; snapshot: `09-snapshot-pub SNAP.P01`, `SNAPI.P01` |
| `publications[*].retention_hours` | | `retention` | online | `P03`, `P04`; `SNAP.P02`, `SNAPI.P02` |
| `publications[*].replicate_ddl` | to_false; to_true | `replicate_ddl` | online | `P05`, `P06`; `18-reverse RV.I.replicate_ddl`, `RV.N.replicate_ddl` |
| `publications[*].allow_pull` | to_false; to_true | `allow_pull` | online | `P07`, `RV.N.allow_pull`; `P08` |
| `publications[*].allow_push` | to_false | `allow_push` | drop_readd, 20012 | `P09`; snapshot `SNAP.P05` |
| `publications[*].allow_push` | to_true | `allow_push` | from `RV.P.allow_push` | `RV.P.allow_push` |
| `publications[*].allow_initialize_from_backup` | to_true; to_false | | online | `P10`, `P11`; `RV.I`, `RV.N` rows; snapshot: refused 18787 `SNAP.P06` |
| `publications[*].allow_subscription_copy` | to_true; to_false | | online | `P12`; `RV.I.allow_subscription_copy` |
| `publications[*].allow_partition_switch` | to_true; to_false | | online | `P14`, `P15`; `RV.*.allow_partition_switch` |
| `publications[*].replicate_partition_switch` | to_true; to_false | | from the rows | `RV.*.replicate_partition_switch_true`, `RV.*.replicate_partition_switch` |
| `publications[*].allow_drop` | to_true; to_false | | online | `P17`, `P18`; `RV.*.allow_drop` |
| `publications[*].status` | set `inactive`; set `active` | `status` | online | `P19`, `P20`; `RV.P.status` |
| `publications[*].immediate_sync` | to_false | | drops_ready | `P23`, `15-snapshot-scope C.native.immediate_sync_false`, `B.native_noanon.1b`; snapshot `SNAPI.P15` |
| `publications[*].immediate_sync` | to_true | | online | `B.native_anon.4a` |
| `publications[*].independent_agent` | both | | drop_readd, 20013 | `P26`; `P25` (21022, the chain) |
| `publications[*].allow_anonymous` | to_true | | online | `P27`; snapshot `SNAPI.P17` |
| `publications[*].allow_anonymous` | to_false | | drops_ready | `B.native_anon.1a`, `B.concurrent_anon.1a` |
| `publications[*].snapshot.alt_folder` | set; clear | `alt_snapshot_folder` | snapshot | `P29`, `P30`, `C.*.alt_snapshot_folder`; `RV.*.alt_snapshot_folder.*`; snapshot `SNAP.P18`, `SNAPI.P18` |
| `publications[*].snapshot.in_default_folder` | to_false; to_true | `snapshot_in_defaultfolder` | snapshot | `P31`; `RV.*.snapshot_in_defaultfolder` |
| `publications[*].snapshot.pre_script`, `post_script` | set; clear | `pre_snapshot_script`, `post_snapshot_script` | snapshot | `P33`, `P34`, `P35`; `RV.*` rows; `SNAP.P21`, `P22` |
| `publications[*].snapshot.ftp.address` | set | `ftp_address` | snapshot | `P38`; `SNAP.P25`, `SNAPI.P25` |
| `publications[*].sync_method` | the pairs of R19 | `sync_method` | snapshot_reinit, wide (concurrent family); snapshot (within `native`, `character`, `database_snapshot`) | `C.native.sync_method`, `D.non_native_pub.change`, `P22` (native>concurrent); `C.concurrent.sync_method`, `P21` (concurrent>native); `C.concurrent_c.sync_method`; `D.non_concurrent.sync_method_probe`, `D.imm_concurrent.sync_method_probe`, `D.non_concurrent_pub.change` (concurrent>concurrent_c); `D.non_concurrent_pub.extend_then_change` (concurrent_c>concurrent, its `change=` cell); `D.non_native.sync_method_probe`, `D.imm_native.sync_method_probe` (native>character); `C.character.sync_method`; `C.dbsnap.sync_method`; snapshot `SNAP.P13`, `SNAPI.P13`, `SNAP.P14`, `SNAPI.P14`, refused 22547 `SNAP.P12`, `SNAPI.P12` |
| `publications[*].articles[*].description` | | `sp_changearticle description` | online | `A01`, `A02`, `A23`; `SNAP.A01`, `SNAPI.A01` |
| `...articles[*].destination.name`, `destination.schema` | | `dest_table`, `destination_owner` | snapshot_reinit | `A03`, `A04`, `A05`; `SNAP.A03` to `A05`, `SNAPI.A03` to `A05` |
| `...articles[*].commands.insert`, `update`, `delete` | | `ins_cmd`, `upd_cmd`, `del_cmd` | online; snapshot publications snapshot_reinit | `A06` to `A09`, `09-snapshot-pub TWIN.A01` to `A04`; `SNAP.A06` to `A09`, `SNAPI.A06` to `A09` |
| `...articles[*].pre_creation_cmd` | | `pre_creation_cmd` | snapshot_reinit | `A10`, `A11`; `SNAP.A10`, `A11` |
| `...articles[*].schema_options` | | `schema_option` | snapshot_reinit | `A12`, `A13`, `05-snapshot-flag S1.O3`, `S3.O3`, `S4.O3`, `C.native.schema_option`; `SNAP.A12`, `SNAPI.A12` |
| `...articles[*].insert_column_names` | to_true; to_false | `status` `include column names`, `no column names` | online | `A14`, `A15`; `RV.*.status.no_column_names` |
| `...articles[*].parameterized` | to_false; to_true | `status` `string literals`, `parameters` | online | `A16`; `RV.*.status.parameters` |
| `...articles[*].creation_script` | set; clear | `creation_script` | snapshot | `A18`; `RV.*.creation_script.*`; `SNAP.A18`, `SNAPI.A18` |
| `...articles[*].fire_triggers_on_snapshot` | to_true; to_false | | online | `A19`; `RV.*.fire_triggers_on_snapshot` |
| `...articles[*].sync_object` | set | `sync_object` | snapshot | `A20`; `SNAP.A20`, `SNAPI.A20` |
| `...articles[*].type` (logbased variants only) | | `type` | snapshot_reinit | `A21`; `SNAP.A21`, `SNAPI.A21` |
| `add_article` | | | snapshot | `05-snapshot-flag S1.O1`, `S2.O1`, `S3.O1`, `S7.O1`; `C.*.addarticle` |
| `drop_article` | | | snapshot | `S1.O2`, `S2.O2`, `S3.O2`, `S7.O2`; `06-structural C2.*`; `C.*.droparticle` |
| `article_filter`, `article_view`, `article_column` | | | snapshot_reinit | `02-matrix F01` to `F06`; `S1.O7` to `O9`, `S3.O7` to `O9`, `S4.O7` to `O9`; `14-filter-view F2bs`, `F2bu`; `C.*.articlefilter`, `articleview`, `articlecolumn`; `SNAP.F01` to `F06`, `SNAPI.F01` to `F06` |
| `add_subscription`, `drop_subscription`, `drop_subscription_article`, `extend_subscription`, `drop_publication` | | | online | `06-structural C1.*`, `C2.*`, `C5.*`; `15-snapshot-scope D.non_native.extend_rule`, `D.non_concurrent.extend_rule` |
| `distributor.min_retention_hours`, `max_retention_hours`, `history_retention_hours` | | `sp_changedistributiondb min_distretention`, `max_distretention`, `history_retention` | online | `07-changes DST.sp_changedistributiondb.*` |
| `distributor.working_directory`, `distributor.publisher_connection.security` | | `sp_changedistpublisher working_directory`, `security_mode` | online | `DST.sp_changedistpublisher.working_directory`, `.security_mode` |
| `publisher.log_reader_agent.connection.login`, `.password_secret` | | `sp_changelogreader_agent @publisher_login`, `@publisher_password` | online | `AGT.sp_changelogreader_agent.publisher_login`, `.publisher_password` |
| `publications[*].snapshot_agent.connection.login`, `.password_secret` | | `sp_changepublication_snapshot @publisher_login`, `@publisher_password` | online | `AGT.sp_changepublication_snapshot.publisher_*` |
| `publications[*].snapshot_agent.schedules` | | `sp_changepublication_snapshot @frequency_*`, `@active_*` (R22) | online | `AGT.sp_changepublication_snapshot.frequency_type+frequency_interval` and the other `AGT.sp_changepublication_snapshot.frequency_*`, `active_*` rows |
| `...subscriptions[*].distribution_agent.connection.security`, `.login`, `.password_secret`, `.subscription_streams`, `.memory_optimized` | | `sp_changesubscription subscriber_security_mode`, `subscriber_login`, `subscriber_password`, `subscriptionstreams`, `memory_optimized` | online | `07-changes SUB.*` |
| `...subscriptions[*].pull_agent.distributor_connection.*`, `.alt_snapshot_folder`, `.working_directory`, `.use_ftp`, `.distributor`, `.memory_optimized` | | `sp_change_subscription_properties` with the property of its row | online | `08-pull P2.*` |
| `agent_profiles[*].description`, `.parameters`, `.default`, profile drop | | the procedures of `19-profiles` | online | `19-profiles PF.*` |
| `profile_binding` | | `[<distribution>].dbo.sp_update_agent_profile` | online | `07-changes PRF.distribution-prefix`, `PRF.distribution-prefix.cwd-distribution` |
| `job_enabled` | | `msdb.dbo.sp_update_job @enabled` | online | `lab/README.md O20` |

  A row whose cells are all errors makes its entry `Refused` with the error of `f11`. A row measured `refused` with one error and expected online by this table (a reverse row of Task 1, say) wins: the entry follows the row, and Task 13 orders the chain the refusal names. The connection `security` changes of the log reader and snapshot agents are refused with 21694 (`AGT.*.publisher_security_mode`); `job_login` changes with 14529 (`AGT.*.job_login`, `SUB`, `08-pull P2.distrib_job_login`): a valid account was never measured, so they are refused. `snapshot.compress`, `snapshot.enabled_for_internet`, the other `ftp.*` keys, `loopback_detection`, `subscriber_type`, the distributor's delete batch sizes, properties, link settings and `trusted`, `publisher_connection.login`, the schedules of other agents, and every reverse direction on a snapshot publication have no entry.

- [ ] Step 1: Write the tests. `TestCostTableMatchesRows`: for each `Cite` of a row file: the row exists; for a flag row (`f00=..,f10=..,f01=..,f11=..`) the least flags whose cell is `ok` (none, then `f10`, then `f01`, then `f11`; none ok is `Refused` with the `f11` error), and for a `15-snapshot-scope` row the combination in its result field (or its `change=` cell), equal `Flags(entry, FlagState{c.Ready, c.At2})`, or the entry's `Refused` error; where the row's detail states `ready=`, `ready_before=` or `immediate_sync_ready=`, it equals `c.Ready`; the row's label contains the entry's `Property` when the row has a label. A cite to `06-structural`, `07-changes`, `08-pull`, `19-profiles` or `lab/README.md` is checked for existence and an `ok` result only. `TestFlagsRule`: `Snapshot` gives (ready, false) for both values of `At2`; `SnapshotReinit` gives (ready, At2); `Online` and `DropsReady` give (false, false). `TestLookupDirections`: `replicate_ddl` `to_true` and `to_false` both found; `publications[*].snapshot.ftp.port` not found; `allow_push` `to_false` is `DropReadd` with 20012. `TestSyncMethodPairs`: the eight transactional pairs of R19 found with their class and `Wide` set exactly for the five concurrent-family pairs; `native>concurrent_c` and `character>concurrent` not found; snapshot `native>character` found, `native>concurrent` `Refused` 22547. `TestEveryEntryCites`: every entry has at least one cite, and every `Procedure` entry a `Property`.
- [ ] Step 2: Run `go test -count=1 -v -run '^(TestCostTableMatchesRows|TestFlagsRule|TestLookupDirections|TestSyncMethodPairs|TestEveryEntryCites)$' ./internal/cost`. Expected: compile failure.
- [ ] Step 3: Write `Table`, `Lookup`, `Flags`, and the row parser of the test.
- [ ] Step 4: Run the Step 2 command. Expected: 5 `--- PASS`.
- [ ] Step 5: Break step. Give `publications[*].alt_folder` the class `SnapshotReinit`: `TestCostTableMatchesRows` fails on `02-matrix P29` (`f10` is ok, `Flags` says both). Restore. Cite `P22` with `Ready: true`: it fails on the detail's `immediate_sync_ready=0`. Restore.
- [ ] Step 6: Commit.

### Task 8: Plan types and calls

Files:
- Create: `internal/plan/plan.go`, `internal/plan/call.go`, `internal/plan/call_test.go`
- Modify: `internal/state/facts.go` (the `Checks` types), `internal/state/facts_test.go`

Interfaces:
- Consumes: `model.Parameters`, `normalize.Lookup`, `normalize.Refusal`, `decode`.
- Produces, in `internal/state`:

```go
type Checks struct {
	Servers             []ServerCheck   `json:"servers"`
	Tables              []TableCheck    `json:"tables"`
	SubscriberDatabases []DatabaseCheck `json:"subscriber_databases"`
	Folders             []FolderCheck   `json:"folders"`
}
type ServerCheck struct {
	Name, Version, Edition, Error string // Error: why it could not be reached
	Reachable                     bool
	Major                         int
}
type TableCheck struct {
	Schema, Name          string
	Exists, HasPrimaryKey bool
	Columns               []string // in column_id order
}
type DatabaseCheck struct {
	Server, Database string
	Checked, Exists  bool
}
type FolderCheck struct {
	Server, Path    string
	Checked, Exists bool
}
```

  (JSON keys in snake case, as `Facts`.)
- Produces, in `internal/plan` (`plan.go`; JSON keys in snake case):

```go
type Refusal = normalize.Refusal

type Cost string // the ten costs of spec "What a plan is":
// online, pending_snapshot_start, new_snapshot, full_generation_deferred,
// ready_snapshot_dropped, reinitialization, drop_and_readd,
// subscriber_data_replaced, subscriber_object_left, shared_object_changed

type Operation struct {
	Seq      int              // 1-based, after ordering
	Step     int              // 1 to 11 of spec "Order"
	Order    string           `json:"-"` // sort key within the step
	Kind     string           // distributor, distribution_db, distpublisher, distributor_property, profile, profile_property, publication_db, log_reader_agent, publication, publication_property, snapshot_agent, article, article_property, article_filter, article_view, article_column, subscription, subscription_extension, subscription_article_drop, push_agent, pull_subscription, pull_agent, agent_property, agent_binding, agent_schedule, job_enabled, generate_and_wait
	Action   string           // add, change, drop, start
	Path     string           // model path of the object
	Changes  []PropertyChange // Path, Before, After string
	Server   string           // the server name as the file writes it
	Database string           // the database the call runs in
	Call     Call
	Costs    []Cost
	Affects  Affects          // Publications, Articles, Subscriptions []string (keys)
	Reason   string
	Sources  []string         // cite rows and spec sections
	Shared   []string         // other publication databases, "<publisher>.<database>"
	Warnings []string
	entry    *cost.Entry      // set by the strategy; the flags pass reads it
}

type Call struct {
	Procedure string  // as rendered: sp_addarticle, msdb.dbo.sp_update_job, [distribution].dbo.sp_update_agent_profile
	Prologue  string  // statements before the EXEC in the same batch (Task 14's id lookups); usually empty
	Params    []Param
}
type Param struct {
	Name   string // @publication
	Value  string // a T-SQL literal: N'x', 1, 0x0000000000030073, NULL
	Secret string // non-empty: a secret name, Value empty (R16)
}

type Plan struct {
	Publisher, Database string
	Options       Options
	Operations    []Operation
	Refusals      []Refusal
	Warnings      []string
	Notes         []string
	Secrets       []SecretUse    // Name string; Set bool; Operations []int (Seq)
	Preconditions []Precondition // Name, Server, Object, Status ("ok", "failed", "unchecked"), Detail
	AgentsToStart []AgentRef     // Kind, Publication, Subscriber, Database, Reason
	Totals        Totals         // Operations, Costly int; ByCost map[Cost]int
}
func (p *Plan) Empty() bool // no operation, no refusal, no agent to start

type Options struct {
	DeferFullSnapshot bool          `json:"defer_full_snapshot"`
	Wait              time.Duration `json:"wait"`
}
type Inputs struct {
	Desired, Current *model.Config
	Facts            *state.Facts
	Checks           *state.Checks          // nil: every precondition unchecked
	SecretSet        func(name string) bool // nil: every secret not set
}
```

- Produces (`call.go`):
  - `type procContext struct { Role, Database, Source string }` and `var procContexts map[string]procContext`, `Role` `publisher`, `distributor` or `subscriber`, `Database` `master`, `publication`, `distribution`, `subscription` or `msdb`:

| Procedures | Role, database | Source |
|---|---|---|
| `sp_adddistributor` | distributor, master | `distributor-defaults X.sp_adddistributor.master` (5001 elsewhere) |
| `sp_adddistributiondb`, `sp_adddistpublisher` | distributor, master | `distributor-defaults X.sp_adddistributiondb.master`, `X.sp_adddistpublisher.master` |
| `sp_replicationdboption` | publisher, master | `12-contexts X.sp_replicationdboption.master` |
| `sp_addlogreader_agent`, `sp_addpublication`, `sp_addpublication_snapshot`, `sp_addarticle`, `sp_articlefilter`, `sp_articleview`, `sp_articlecolumn`, `sp_addsubscription`, `sp_addpushsubscription_agent` | publisher, publication | `12-contexts X.<procedure>.Sales` (`X.sp_addsubscription.push.Sales`, `.pull.Sales`) |
| `sp_changepublication`, `sp_changearticle`, `sp_changesubscription`, `sp_changelogreader_agent`, `sp_changepublication_snapshot`, `sp_dropsubscription`, `sp_droparticle`, `sp_droppublication`, `sp_startpublication_snapshot` | publisher, publication | `02-matrix`, `07-changes`, `06-structural` (`USE Sales` in each) |
| `sp_addpullsubscription`, `sp_addpullsubscription_agent`, `sp_change_subscription_properties`, `sp_droppullsubscription` | subscriber, subscription | `12-contexts X.sp_addpullsubscription.m_ctx`, `08-pull P2.*`, `P3.*` |
| `sp_add_agent_profile` and the procedures of `19-profiles` | distributor, master | `12-contexts X.sp_add_agent_profile.master`, `19-profiles` |
| `sp_update_agent_profile` | distributor, distribution, called `[<distribution db>].dbo.sp_update_agent_profile` | `07-changes PRF.distribution-prefix.cwd-distribution` |
| `sp_changedistributiondb`, `sp_changedistpublisher` | distributor, the database `07-changes` uses for `DST.*` (read it) | `07-changes DST.*` |
| `msdb.dbo.sp_update_job` | the job's server, msdb | `O20` |

  - `type encoder func(v any) (literal string, err error)` and `var encoders map[string]encoder`, keyed `<procedure>.@<param>`, and `var neverPassed map[string]string` (key to reason: `job_name` parameters, never compared; `creation_only` parameters of objects the plan does not create). Encodings: booleans `N'true'`/`N'false'`; `sync_method` with spaces (`database_snapshot` is `N'database snapshot'`, `database_snapshot_character` `N'database snapshot character'`, `concurrent_c` `N'concurrent_c'`); `@repl_freq` `N'continuous'` for `transactional`; article `@type` with spaces (`proc_schema_only` is `N'proc schema only'`, `logbased_manualfilter` `N'logbased manualfilter'`); `@schema_option` `0x` and 16 hex digits of `EncodeSchemaOptions`; `@status` of `sp_addarticle` the integer `8*insert_column_names + 16*parameterized`; commands `N'CALL [dbo].[p]'` through `decode.Command.String`; `@sync_type` `N'automatic'` for `snapshot`, `N'replication support only'`, `N'initialize with backup'`; security modes `0`/`1`; frequencies the `FreqTypeCode` integer; strings `N'...'` with `'` doubled; `""` is `NULL`.
  - `func creationCall(proc string, obj any, ctx normalize.Context, identity []Param) (Call, error)`: walks the `model.Parameters` entries of `proc`, resolves each path under `obj`, and keeps a parameter by R15.
  - `func literal(s string) string` (`N'` + doubled quotes + `'`).

- [ ] Step 1: Write the tests. `TestEncodersCoverParameters`: every `field` or `creation_only` entry of `model.Parameters` for a procedure of `procContexts` with `Since` at most `2022` has an encoder or a `neverPassed` reason. `TestProcContextsCiteRows`: every `X.` source exists in `12-contexts.txt` or `distributor-defaults.txt` with an `ok` result; every other source names an existing results file. `TestLiteralQuoting`: `literal("a'b")` is `N'a''b'`. `TestEncodeValues`: the encodings above, one case each. `TestCreationCallPassesOnlyNonDefaults`: `sp_addpublication` for a normalized publication `P` at its transactional defaults except `retention_hours` 100, `immediate_sync` true, `independent_agent` true and `status` `active` gives exactly `@publication = N'P'`, `@retention = 100`, `@independent_agent = N'true'`, `@immediate_sync = N'true'`, `@status = N'active'`, in `model.Parameters` order. `TestChecksJSONKeys` (`internal/state`): the keys of `Checks` and its four element types.
- [ ] Step 2: Run `go test -count=1 -v -run '^(TestEncodersCoverParameters|TestProcContextsCiteRows|TestLiteralQuoting|TestEncodeValues|TestCreationCallPassesOnlyNonDefaults)$' ./internal/plan` and `go test -count=1 -v -run '^TestChecksJSONKeys$' ./internal/state`. Expected: compile failures.
- [ ] Step 3: Implement.
- [ ] Step 4: Run the Step 2 commands. Expected: 5 and 1 `--- PASS`.
- [ ] Step 5: Break step. Encode `database_snapshot` as `N'database_snapshot'`: `TestEncodeValues` fails. Restore. Remove the encoder of `sp_addarticle.@schema_option`: `TestEncodersCoverParameters` fails naming it. Restore.
- [ ] Step 6: Commit.

### Task 9: State prediction, flags and costs

Files:
- Create: `internal/plan/state.go`, `internal/plan/finish.go`, `internal/plan/state_test.go`

Interfaces:
- Consumes: `Operation`, `Call` (Task 8), `cost.Flags`, `state.Facts`.
- Produces:

```go
type State struct {
	Pubs      map[string]*PubState // by publication name
	LogReader bool
}
type PubState struct {
	Exists, ImmediateSync, AllowAnonymous, Ready bool
	Type, SyncMethod                             string
	Articles                                     map[string]bool          // name to active bit
	Subs                                         map[string]*SubState     // by lower-cased Subscription.Key()
	SnapshotRecurring                            bool                     // R25 refusals read it
}
type SubState struct {
	Rows map[string]int // article to publisher status
}

func NewState(cur *model.Config, f *state.Facts) *State
func (s *State) Pending(pub string) bool                          // R12
func (s *State) apply(op *Operation)                              // R10
func agentStatus(a state.AgentFacts, since string) string          // R13: running, stopped, failed, retrying, unknown

// finish orders ops by (Step, Order), then walks them in that order:
// computes each op's flag params and costs from its entry and the
// predicted state, applies the transition, and numbers Seq. The refusals
// are the combinations only the predicted state shows (Tasks 11 and 13).
func finish(ops []Operation, st *State) ([]Operation, []Refusal)
```

- Costs computed in `finish` from the class: `online` gives `online`; `snapshot` gives R11's; `snapshot_reinit` with the reinit flag gives `reinitialization` (the subscriptions with a row at 2 in `Affects`) and `new_snapshot`, without it `pending_snapshot_start` when rows of the article are at 1, `online` when the article has no subscription; `drops_ready` gives `ready_snapshot_dropped`, or `full_generation_deferred` when the publication keeps `immediate_sync` (spec "Publication properties"); a strategy's own costs (`drop_and_readd`, `subscriber_data_replaced`, `subscriber_object_left`, `shared_object_changed`) are kept. `Totals.Costly` counts the operations with any cost other than `online` and `shared_object_changed`.

- [ ] Step 1: Write the tests. `TestNewStateFromFacts`: from the lab fixture, `SalesPub` has `Ready` true and `ImmediateSync` true, `SalesRef` `Ready` false, each subscription one row per article at 2. `TestPendingDefinition`: a row at 1 is pending; on a publication without `immediate_sync`, an inactive subscribed article is pending; on an `immediate_sync` publication an inactive article with every row at 2 is not. `TestPredictAddArticle`: `SalesPub` ready, an `add_article` op of `m_t9` with its entry: the flag param `@force_invalidate_snapshot = 1` is added, then `Ready` is false and every subscription has `m_t9` at 1; a second `add_article` in the same list gets no flag. `TestPredictReinitMarks`: a `schema_options` change of `Customer` on `SalesPub` gets both flags and sets `Customer`'s rows to 1, the other articles' rows stay 2; a following `pre_creation_cmd` change of `Customer` gets no reinit flag; a `concurrent>native` `sync_method` change marks every row 1. `TestPredictImmediateSyncFalse`: after it, an `add_article` gets no flag (spec, hypothesis of the panel, Mistral). `TestPredictAddSubscription`: on a ready `immediate_sync` publication the new rows are at 2 (`S7`), on `SalesRef` at 1. `TestAgentStatus`: no job `unknown`; running job with last runstatus 3 `running`; running job with last runstatus 5 `retrying`; stopped job, `last_failure` after `last_generation`, last runstatus 6 `failed`; the same with `last_failure` before `last_generation` `stopped`.
- [ ] Step 2: Run `go test -count=1 -v -run '^(TestNewStateFromFacts|TestPendingDefinition|TestPredictAddArticle|TestPredictReinitMarks|TestPredictImmediateSyncFalse|TestPredictAddSubscription|TestAgentStatus)$' ./internal/plan`. Expected: compile failure.
- [ ] Step 3: Implement.
- [ ] Step 4: Run the Step 2 command. Expected: 7 `--- PASS`.
- [ ] Step 5: Break step. Compute the flags from the state before the first operation instead of the predicted one: `TestPredictAddArticle` fails on the second `add_article`, `TestPredictImmediateSyncFalse` fails. Restore. Read the inactive article as pending on `immediate_sync` publications too: `TestPendingDefinition` fails. Restore.
- [ ] Step 6: Commit.

### Task 10: Comparison and the Build skeleton

Files:
- Create: `internal/plan/diff.go`, `internal/plan/build.go`, `internal/plan/diff_test.go`, `internal/plan/pure_test.go`

Interfaces:
- Consumes: `normalize.Normalize` (Task 6), `cost.Lookup`, `NewState`, `finish` (Task 9).
- Produces:

```go
type Change struct {
	Path, Pattern string // publications[P].retention_hours, publications[*].retention_hours
	Before, After *string // model values; nil is absent
}

// diffObject compares the scalar properties of two objects of one type, by
// YAML tag, pointers and the non-pointer fields named in R-folds alike, and
// skips the paths skip returns true for.
func diffObject(path string, desired, current any, skip func(path string) bool) []Change

func notCompared(pattern string) bool // job_name, run_as, command, generated schedule names, initialization, findings, the derived bits

// Build: Normalize, refuse on out_of_scope (R26), normalize the current
// side's R14 bit, match objects (R7), call the strategies, finish.
func Build(in Inputs, opt Options) *Plan

type strategy func(b *builder)
var strategies []strategy // Tasks 11 to 14 append theirs; the order of operations is finish's sort by (Step, Order), never the order of registration
type builder struct {
	in              Inputs
	opt             Options
	des, cur        *model.Config // normalized desired, current
	st              *State
	ops             []Operation
	refusals        []Refusal
	warnings, notes []string
	skip            func(path string) bool // the unreadable paths
}
func (b *builder) refuse(path, format string, args ...any)
func (b *builder) unmeasured(c Change) // refuse(c.Path, "cost of %s change not measured", c.Pattern)
```

- Matching: `matchPublications`, `matchArticles`, `matchSubscriptions` (`strings.EqualFold` on subscriber and database), `matchProfiles`, each returning pairs, desired-only and current-only lists, sorted by key. Schedules (R22): `default` (nil desired) compares `frequency`, `interval`, `subday`, `subday_interval` with the current schedule; a declared one every field except `name`.

- [ ] Step 1: Write the tests. `TestDiffScalars`: retention 336 against 100 gives one `Change` with pattern `publications[*].retention_hours`, before `100`, after `336`; equal objects give none. `TestDiffSkipsUnreadable`: a current with an `unreadable` finding at `publications[P].snapshot_agent.run_as` and a nil value, a desired `""`: no change, and `Build` gives one note naming the path. `TestDiffNotCompared`: differences of `job_name`, `run_as`, `command`, a schedule's `name` and a subscription's `initialization` give no change. `TestDiffMatchesSubscriptionsIgnoringCase`: desired `repllab/salessub` matches current `REPLLAB/SalesSub`: one pair, nothing desired-only or current-only. `TestDiffNilAndEmptyLists`: `columns` nil, `[]` and the full column list from `Checks.Tables` are equal (R30). `TestDiffSchedulesFrequencyOnly`: a nil desired schedule against the current daily 5-minute schedule with another `start_date` gives no change; a declared schedule with another `start_date` gives one. `TestBuildRefusesOutOfScope`: a current with two `out_of_scope` findings gives two refusals and no operation. `TestPurePackages`: the non-test files of `internal/normalize`, `internal/cost` and `internal/plan`, parsed with `go/parser`, import neither `database/sql` nor `internal/reader` nor `internal/precheck`.
- [ ] Step 2: Run `go test -count=1 -v -run '^(TestDiffScalars|TestDiffSkipsUnreadable|TestDiffNotCompared|TestDiffMatchesSubscriptionsIgnoringCase|TestDiffNilAndEmptyLists|TestDiffSchedulesFrequencyOnly|TestBuildRefusesOutOfScope|TestPurePackages)$' ./internal/plan`. Expected: compile failure.
- [ ] Step 3: Implement.
- [ ] Step 4: Run the Step 2 command. Expected: 8 `--- PASS`.
- [ ] Step 5: Break step. Compare subscriber names exactly: `TestDiffMatchesSubscriptionsIgnoringCase` fails. Restore. Add `import _ "database/sql"` to `internal/plan/build.go`: `TestPurePackages` fails. Restore.
- [ ] Step 6: Commit.

### Task 11: Articles, filters, columns and views

Files:
- Create: `internal/plan/articles.go`, `internal/plan/articles_test.go`, `internal/plan/publications.go` (the add and drop of publications and their snapshot agents)

Interfaces:
- Consumes: `builder`, `creationCall`, `cost.Lookup` (`add_article`, `drop_article`, `article_filter`, `article_view`, `article_column`, the article property entries).
- Produces: the strategy `articlesStrategy` and `publicationsStrategy` appended to `strategies`; operations, by spec "Strategies" and "Order":
  - add a publication (step 8): `sp_addpublication`, then `sp_addpublication_snapshot` (the snapshot agent of the file; R22 schedule), then its articles; when step 5 dropped the database's last publication or the database has no log reader, `sp_addlogreader_agent` first (step 3 or 8, spec "Order" step 8).
  - add an article (step 8): `sp_addarticle` from `creationCall`, never with `@filter_clause` (lab row 12); then, for a filter, `sp_articlefilter @filter_name, @filter_clause` then `sp_articleview @view_name, @filter_clause` with the same clause; for columns, one `sp_articlecolumn @operation = N'drop'` per column absent from `columns` (the table's columns from `Checks`; refused "columns of %s not read" when absent), then `sp_articleview` with the clause.
  - drop an article (steps 4 and 5): `sp_dropsubscription @article` for each subscription to it, then `sp_droparticle`; cost "subscriber object left behind" on the drops.
  - drop a publication (steps 4 and 5): `sp_dropsubscription @article = N'all'` per subscription, then `sp_droppublication`; a warning when its snapshot agent's `run_as` is not empty: "dropping the publication deletes its snapshot job and the proxy of its job step" (ledger).
  - change an article property (step 7): one `sp_changearticle` per `Change`, its entry from `cost.Lookup`, `unmeasured` otherwise; a `pre_creation_cmd` change, and any reinitialization of an article whose `pre_creation_cmd` is `drop`, `delete` or `truncate`, adds `subscriber_data_replaced` (spec anti-goal 4).
  - change a filter (step 7): clause or procedure: `sp_articlefilter` then `sp_articleview` with the clause; drop: `sp_articlefilter @filter_clause = NULL` then `sp_articleview @filter_clause = NULL` (spec "Filters and views"); columns: the `sp_articlecolumn` calls (`add` or `drop`), then `sp_articleview` with the clause; `sp_articleview` is never called without the article's clause.
  - R20: a type family or `source` change is a drop and an add; refusals for `proc_exec` articles.
  - the refusal of spec "Strategies": an `sp_addarticle` on an `immediate_sync` publication whose every subscription row is predicted at 1 by an earlier `sync_method` change of the same plan: "cost of the snapshot after sp_addarticle on a publication reinitialization not measured". The check runs in `finish`'s walk, which knows the predicted state: the strategy marks the op, `finish` refuses.

- [ ] Step 1: Write the tests, each a `Build` on the lab fixture or a small configuration, asserting the operations' `Kind`, `Call.Procedure`, the presence or absence of the two flag parameters, `Costs`, `Affects` and a `Sources` entry. `TestAddArticleImmediateSync`: `m_t9` added to `SalesPub` (ready): one `sp_addarticle` with `@force_invalidate_snapshot = 1`, no `sp_addsubscription`, costs `[new_snapshot]`, source `05-snapshot-flag S1.O1`. `TestAddArticleNonImmediateNative`: `m_t9` added to `SalesRef` (`native`): `sp_addarticle` with no flag, then `sp_addsubscription @article = N'm_t9'` for `REPLLAB/SalesSub`. `TestAddArticleNonImmediateConcurrent`: the same on a `concurrent` publication without `immediate_sync`: the extension has `@article = N'all'`. `TestAddArticleAfterWideMarkRefused`: on `SalesPub`, `sync_method` `concurrent>native` and an added article in one file: one refusal with the message above. `TestDropArticle`: `Product` dropped from `SalesRef`: `sp_dropsubscription @article = N'Product'` then `sp_droparticle` without flag, costs online plus `subscriber_object_left`; `Orders` dropped from `SalesPub`: `sp_droparticle` with the flag, cost `full_generation_deferred`. `TestArticleSourceChangeIsDropAndAdd`: an article whose source changes gives a drop then an add, in steps 5 and 8. `TestFilterChangeSequence`: `Customer`'s clause changed: `sp_articlefilter` then `sp_articleview`, adjacent, same `@filter_clause`, both flags on the first (ready, rows at 2), none on the second (predicted), cost `reinitialization` naming `REPLLAB/SalesSub`. `TestFilterDrop`: `@filter_clause = NULL` on both calls. `TestColumnChangeReissuesView`: a column added back gives `sp_articlecolumn @operation = N'add'` then `sp_articleview` with the article's clause. `TestNeverAddArticleFilterClause`: no `sp_addarticle` of any test carries `@filter_clause`. `TestArticlePropertyFlags`: `schema_options` of `Orders` on `SalesPub`: both flags, costs `reinitialization`, `new_snapshot`, `subscriber_data_replaced` (`pre_creation_cmd` `drop`); `description`: online. `TestMoveArticle`: an article moved from `P1` to `P2` gives its drop from `P1` (step 5) and its add to `P2` (step 8). `TestDropPublicationProxyWarning`: a dropped publication whose snapshot agent has `run_as` `DOMAIN\svc` carries the warning.
- [ ] Step 2: Run `go test -count=1 -v -run '^(TestAddArticleImmediateSync|TestAddArticleNonImmediateNative|TestAddArticleNonImmediateConcurrent|TestAddArticleAfterWideMarkRefused|TestDropArticle|TestArticleSourceChangeIsDropAndAdd|TestFilterChangeSequence|TestFilterDrop|TestColumnChangeReissuesView|TestNeverAddArticleFilterClause|TestArticlePropertyFlags|TestMoveArticle|TestDropPublicationProxyWarning)$' ./internal/plan`. Expected: compile failure.
- [ ] Step 3: Implement.
- [ ] Step 4: Run the Step 2 command. Expected: 13 `--- PASS`.
- [ ] Step 5: Break step. Emit `sp_articleview` without `@filter_clause` after a column change: `TestColumnChangeReissuesView` fails. Restore. Give the extension `@article = <name>` on `concurrent`: `TestAddArticleNonImmediateConcurrent` fails. Restore.
- [ ] Step 6: Commit.

### Task 12: Subscriptions

Files:
- Create: `internal/plan/subscriptions.go`, `internal/plan/subscriptions_test.go`

Interfaces:
- Consumes: `builder`, `creationCall`, `Publication.SubsetAllowed`.
- Produces: `subscriptionsStrategy`; operations by spec "Subscriptions" and "Order" step 9:
  - push: `sp_addsubscription` then `sp_addpushsubscription_agent`, consecutive `Order` keys so nothing sorts between them; `@article` `N'all'` when the file subscribes every article, otherwise one `sp_addsubscription` per article by name (allowed only where `SubsetAllowed`).
  - pull: `sp_addsubscription @subscription_type = N'pull'` at the publisher, then `sp_addpullsubscription` (`@subscription_type = N'pull'`, `@independent_agent` and `@immediate_sync` the publication's values) and `sp_addpullsubscription_agent` at the subscriber.
  - drop: push `sp_dropsubscription @article = N'all'`; pull `sp_droppullsubscription` at the subscriber, then `sp_dropsubscription` at the publisher (`08-pull P3.subscriber-first.*`); an article removed from a subset `sp_dropsubscription @article = <name>`; an article added to a subset an extension by name.
  - completion of an intermediate state (spec "Subscriptions", R26): a current subscription with an `incomplete` finding at `...articles` whose missing article the file keeps gets `sp_addsubscription @article = N'all'`; one whose missing article the file drops gets nothing more than the article's drop.
  - R21 refusals and notes; agent property changes of the push and pull agents through `cost.Lookup` (Task 14 owns the profile binding and schedules).
  - a dropped pull subscription that is the last one of a shared pull agent: warning "the shared pull agent job stays at the subscriber after sp_droppullsubscription", cost `subscriber_object_left` (ledger).

- [ ] Step 1: Write the tests. `TestAddPushSubscriptionUnit`: a new push subscription gives `sp_addsubscription` then `sp_addpushsubscription_agent` with consecutive `Seq`, even with another publication's articles in the same plan. `TestAddPullSubscription`: three operations, the first at the publisher in the publication database, the two others at the subscriber in the subscription database, each with `@subscription_type = N'pull'` where it applies, `@immediate_sync = N'false'` for a publication without it. `TestDropPullOrder`: `sp_droppullsubscription` before `sp_dropsubscription`. `TestDropWholeSubscription`: `@article = N'all'`. `TestSubsetRules`: a subset on `SalesPub` (`immediate_sync`) is refused by normalization (14122); on `SalesRef` it gives one `sp_addsubscription` per article. `TestCompleteIntermediateSubscription`: current `SalesRef` subscription with an `incomplete` finding at its `articles` and `Product` missing, desired keeping `Product`: one `sp_addsubscription @article = N'all'`, no drop of the subscription. `TestPullNonIndependentRefused`, `TestLsnInitializationRefused`, `TestTypeChangeRefused`: one refusal each, with R21's text. `TestInitializationChangeNote`: `snapshot` to `replication_support_only` on an existing subscription: no operation, one note. `TestDropLastPullOfSharedAgentWarns`: the warning and the cost.
- [ ] Step 2: Run `go test -count=1 -v -run '^(TestAddPushSubscriptionUnit|TestAddPullSubscription|TestDropPullOrder|TestDropWholeSubscription|TestSubsetRules|TestCompleteIntermediateSubscription|TestPullNonIndependentRefused|TestLsnInitializationRefused|TestTypeChangeRefused|TestInitializationChangeNote|TestDropLastPullOfSharedAgentWarns)$' ./internal/plan`. Expected: compile failure.
- [ ] Step 3: Implement.
- [ ] Step 4: Run the Step 2 command. Expected: 11 `--- PASS`.
- [ ] Step 5: Break step. Order the pull drop publisher first: `TestDropPullOrder` fails. Restore. Complete the intermediate state by dropping and re-adding the subscription: `TestCompleteIntermediateSubscription` fails. Restore.
- [ ] Step 6: Commit.

### Task 13: Publication properties and the deferred snapshot

Files:
- Create: `internal/plan/properties.go`, `internal/plan/defer.go`, `internal/plan/properties_test.go`

Interfaces:
- Consumes: `builder`, `cost.Lookup`, the subscription operations of Task 12.
- Produces: `propertiesStrategy` (step 6), `deferStrategy`:
  - one `sp_changepublication` per `Change`, ordered by the chains (spec "Publication properties"): enable bottom up (`independent_agent`, `immediate_sync`, `allow_anonymous`; `alt_folder` before `compress`; `ftp.address` before `enabled_for_internet`; `allow_partition_switch` before `replicate_partition_switch`), disable top down; plus any chain a Task 1 row showed refused (`snapshot_in_defaultfolder` true before an `alt_folder` clear, if `RV.*.alt_snapshot_folder.*` was refused while it was false).
  - `drop_readd` entries (`independent_agent`, `allow_push` to false with push subscriptions): the subscriptions are dropped in step 4, `immediate_sync` set false first where it is true (21022), the property changed, `immediate_sync` restored, and the subscriptions re-added in step 9 with snapshot initialization, costs `drop_and_readd` and `reinitialization` on the re-add; the re-add uses the file's article list (by name for a subset, `N'all'` only for every article, `N'all'` on the concurrent family); refused before any drop when a subscription's `initialization` is not `snapshot` (spec: the plan refuses and names the two ways, a fresh `COPY_ONLY` backup or `initialize from lsn` with the subscriber's `transaction_timestamp`) or when its subset cannot be re-added in the form the publication accepts then.
  - costs of `allow_anonymous` false and `immediate_sync` false by spec "Publication properties" (through `finish`'s `drops_ready` rule; when both go false the first carries `ready_snapshot_dropped` and the second is online, because the state is no longer ready).
  - `-defer-full-snapshot`, for each publication of the file with `immediate_sync` and an added article: `allow_anonymous` false when true, `immediate_sync` false (step 6), the add and the extension by the rules without `immediate_sync` (steps 8, 9), a `generate_and_wait` operation (R25, end of step 9), then `immediate_sync` true and `allow_anonymous` true (end of step 9). Refusals: `sync_method` other than `native` and `concurrent` ("cost of deferred snapshot not measured"); the current snapshot agent schedule recurring, or the file making it recurring in this plan ("the deferral would last until the next scheduled run", asking for two plans); `Wait == 0`. The summary note "the full generation is deferred to the next run of the snapshot agent of %s".
  - the spec's second combination refusal: a named extension on a `native` or `character` publication whose every row is predicted at 1 by a `sync_method` change of this plan: "cost of the snapshot after an extension on a publication reinitialization not measured", asking for two plans (checked in `finish`, as Task 11's).

- [ ] Step 1: Write the tests. `TestChainOrder`: a file enabling `independent_agent`, `immediate_sync` and `allow_anonymous` on a publication without subscriptions gives them in that order; disabling gives the reverse. `TestIndependentAgentDropReadd`: `SalesRef` to `independent_agent` true: its subscription dropped in step 4, the change in step 6, the re-add in step 9 with `@article = N'all'`, costs `drop_and_readd`, `reinitialization`. `TestDropReaddRefusedForNonSnapshotInit`: the same with the subscription's `initialization` `replication_support_only`: one refusal naming the two ways, no operation. `TestImmediateSyncFalseCosts`: on `SalesPub` (ready, `allow_anonymous` false) `immediate_sync` false: `ready_snapshot_dropped`; a publication with `allow_anonymous` true going false with `immediate_sync` kept: `full_generation_deferred`; both going false: the first `ready_snapshot_dropped`, the second `online`. `TestSyncMethodCosts`: `SalesPub` `concurrent>native`: both flags, `reinitialization` of every subscription, `new_snapshot`; `SalesRef` `native>character`: no flag, `online`. `TestSyncMethodUnmeasuredRefused`: `native>concurrent_c` is refused with "cost of publications[*].sync_method change not measured". `TestDeferSequence`: `SalesPub`-like `native` publication, snapshot schedule `once`, `allow_anonymous` true, an added article, the option set: the operations in this order: `allow_anonymous` false, `immediate_sync` false, `sp_addarticle` without flag, `sp_addsubscription @article = <name>`, `generate_and_wait`, `immediate_sync` true, `allow_anonymous` true. `TestDeferRefusals`: `character`; a recurring current schedule; an on-demand schedule made daily by the file; `Wait` 0: four refusals. `TestOnlinePropertyChange`: `retention_hours` alone: one operation, `online`. `TestSnapshotClassCost`: `alt_folder` set on `SalesPub`: the snapshot flag, cost `full_generation_deferred`; on `SalesRef`: no flag, `online`.
- [ ] Step 2: Run `go test -count=1 -v -run '^(TestChainOrder|TestIndependentAgentDropReadd|TestDropReaddRefusedForNonSnapshotInit|TestImmediateSyncFalseCosts|TestSyncMethodCosts|TestSyncMethodUnmeasuredRefused|TestDeferSequence|TestDeferRefusals|TestOnlinePropertyChange|TestSnapshotClassCost)$' ./internal/plan`. Expected: compile failure.
- [ ] Step 3: Implement.
- [ ] Step 4: Run the Step 2 command. Expected: 10 `--- PASS`.
- [ ] Step 5: Break step. Restore `immediate_sync` before `generate_and_wait`: `TestDeferSequence` fails. Restore. Enable the chain top down: `TestChainOrder` fails. Restore.
- [ ] Step 6: Commit.

### Task 14: Distributor, profiles, agents and schedules

Files:
- Create: `internal/plan/distributor.go`, `internal/plan/agents.go`, `internal/plan/distributor_test.go`

Interfaces:
- Consumes: `builder`, `creationCall`, `Facts.PublisherDatabases`, `Facts.ProfileUses`.
- Produces: `distributorStrategy` (steps 1, 2, 11), `agentsStrategy` (steps 3, 10):
  - distributor (step 1, R17): none at the publisher and the file's distributor equal to the publisher (case-insensitive): `sp_adddistributor @distributor` (master), `sp_adddistributiondb`, `sp_adddistpublisher`; the distributor exists and this publisher is not registered (current `Distributor{Server}` only) and is local: `sp_adddistpublisher`; a remote one: R17's refusal; the file naming another distributor than the one in place, or remote where it is local: refused "moving a publication database to another distributor drops every publication (spec Non-goals)". Changes: the entries of the cost table, every one carrying `shared_object_changed` and `Shared` (the other `PublisherDatabases`) when that list is not empty; a change of a property no procedure changes (`data_folder` and the like, declared and different) refused "no procedure changes %s of an existing distribution database".
  - profiles (step 2 create and change, step 11 drop, R6): `sp_add_agent_profile` then one `sp_add_agent_parameter` per parameter; changes and drops by the `19-profiles` entries; all `shared_object_changed` with `Shared`.
  - publication database (step 3): `sp_replicationdboption @dbname, @optname = N'publish', @value = N'true'` when the database is not published and the file has a transactional or snapshot publication; `sp_addlogreader_agent` when `NeedsLogReader` and none exists (also the repair of the `incomplete` finding at `publisher.log_reader_agent`).
  - agents (step 10): profile binding by `[<distribution>].dbo.sp_update_agent_profile @agent_type, @agent_id, @profile_id`, after the profile's creation. The agent and the profile may not exist when `plan` runs, so the ids are read in the same batch: `Call.Prologue` is `DECLARE @agent_id int, @profile_id int;` followed by two `SELECT`s of them, the agent from its `MS*_agents` row by publisher database, publication, subscriber and subscription database (as the reader finds it), the profile from `msdb.dbo.MSagent_profiles` by name and agent type, then `IF @agent_id IS NULL OR @profile_id IS NULL THROW 50000, N'<what is missing>', 1;`, and the call passes the variables; snapshot schedule by R22; `job_enabled` by R23; the snapshot agent of an existing publication without one (the repair of `publications[*].snapshot_agent`): `sp_addpublication_snapshot` in step 8; every other agent change through `cost.Lookup`, `unmeasured` otherwise.

- [ ] Step 1: Write the tests. `TestDistributorCreateLocal`: an empty current (no distributor) and a file whose distributor is the publisher: three operations in step 1, the first in `master`, `Shared` empty. `TestDistributorRemoteRefused` and `TestDistributorMoveRefused`: one refusal each. `TestDistributorChangeShared`: the fixture's current with `PublisherDatabases` holding `Sales` and `Other`, a file with `max_retention_hours` 96: one `sp_changedistributiondb`, costs `[online, shared_object_changed]`, `Shared` `["<publisher>.Other"]`. `TestProfileCreateBeforeBinding`: a new profile bound to a new push agent: `sp_add_agent_profile` in step 2, the binding in step 10. `TestProfileDropOnlyUnused`: a profile absent from the file and named by a `ProfileUses` row in another case (`LAB-DISTRIB`), or by a `virtual` row: no drop; absent and unused: one drop in step 11. `TestAgentBindingCall`: the procedure is `[distribution].dbo.sp_update_agent_profile` for the lab's distribution database. `TestSnapshotScheduleChange`: a declared daily schedule every 10 minutes on `SalesPub`: one `sp_changepublication_snapshot` passing `@frequency_type = 4`, `@frequency_interval = 1`, `@frequency_subday = 4`, `@frequency_subday_interval = 10` and the four `@active_*` values. `TestUnmeasuredAgentChangesRefused`: a push distribution agent schedule change and a log reader `job_login` change: two refusals. `TestJobEnabledReenable`: current snapshot agent `job_enabled` false, desired omitted: one `msdb.dbo.sp_update_job @enabled = 1`, `online`. `TestLogReaderCreatedForNewDatabase`: a database not published and a file with one transactional publication: `sp_replicationdboption` and `sp_addlogreader_agent` in step 3, before `sp_addpublication`.
- [ ] Step 2: Run `go test -count=1 -v -run '^(TestDistributorCreateLocal|TestDistributorRemoteRefused|TestDistributorMoveRefused|TestDistributorChangeShared|TestProfileCreateBeforeBinding|TestProfileDropOnlyUnused|TestAgentBindingCall|TestSnapshotScheduleChange|TestUnmeasuredAgentChangesRefused|TestJobEnabledReenable|TestLogReaderCreatedForNewDatabase)$' ./internal/plan`. Expected: compile failure.
- [ ] Step 3: Implement.
- [ ] Step 4: Run the Step 2 command. Expected: 11 `--- PASS`.
- [ ] Step 5: Break step. Compare `ProfileUses` names exactly: `TestProfileDropOnlyUnused` fails on `LAB-DISTRIB`. Restore. Call `msdb.dbo.sp_update_agent_profile`: `TestAgentBindingCall` fails. Restore.
- [ ] Step 6: Commit.

### Task 15: Plan-level lists

Files:
- Create: `internal/plan/lists.go`, `internal/plan/build_test.go`

Interfaces:
- Consumes: everything above; `state.Checks`.
- Produces, filled by `Build` after `finish`:
  - `Refusals` from R18 (`Checks.Servers` `Major` not 16), R26 (the `incomplete` findings outside the repair list: the paths ending in `snapshot_agent`, `log_reader_agent`, `.articles` of a subscription, `.filter`, `.sync_object`), and the preconditions that refuse: a published table missing (`Exists` false) or, for a table article of a transactional publication, without a primary key ("error 14088"), a subscriber database missing for a subscription the plan creates.
  - `Preconditions`: one per table, subscriber database and snapshot folder the plan relies on, `ok`, `failed` or `unchecked` (no `Checks`, or `Checked` false); a missing snapshot folder is `failed` with a warning, never a refusal (spec "Non-goals"); `database_snapshot` and `database_snapshot_character` need the Enterprise or Developer edition of the publisher (`ServerCheck.Edition`), a refusal otherwise.
  - `Secrets`: every `Param.Secret` of the operations, sorted, with `SecretSet` and the `Seq` of each use.
  - `AgentsToStart` (R24): each publication `State.Pending` after the last operation, and each publication pending before the plan, with reason `pending`; the subscriptions whose rows are predicted at 1, with reason `delivery`.
  - `Warnings`: per publication of the file using `native` or `character`, the text "publication %s uses %s, which locks the published tables for most of each generation; moving to concurrent costs %s; concurrent and concurrent_c still lock the tables briefly near the start and the end of each run; the cost of a move to database snapshot is not measured", the cost read from the predicted state (a reinitialization of every subscription when a row is at 2, plus the snapshot flag when ready); per publication with `immediate_sync` and a recurring snapshot schedule, "publication %s generates every article at every run of its snapshot agent (%s)"; per subscription whose distribution agent is not `running` (R13), "distribution agent of %s is %s; plan cannot see a snapshot generated and not delivered (campaign item 14)", and for a `concurrent` or `concurrent_c` subscription with a `distributor_status` 3 row, the log reader's status; R32's command line warning.
  - `Notes`: the unreadable paths; an `immediate_sync` publication not ready with nothing pending, "full generation deferred to the next run of the snapshot agent of %s" (spec "Inputs"); R21's initialization note.
  - `Totals`.

- [ ] Step 1: Write the tests. `TestBuildExportIsEmpty`: the fixture as desired and current with its facts and `Checks` built from it (every table found with its key and columns, every server major 16): no operation, no refusal, `Empty()` true; any warning is allowed. `TestBuildOrderSteps`: a file that creates a profile, a publication with two articles, a filter and a push subscription bound to the profile, and drops another publication with its subscription: `Step` never decreases along `Seq`; the drops of step 4 come before step 5's; `sp_add_agent_profile` before the binding; `sp_addpublication` before its `sp_addarticle`; every `sp_addarticle` before any `sp_addsubscription` of the same publication. `TestBuildRepairsIncomplete`: a current with the `incomplete` finding at `publications[SalesRef].snapshot_agent` and the file's snapshot agent: one `sp_addpublication_snapshot`; a current with the finding "articles disagree on subscription_type": one refusal "repair of this state is not measured". `TestBuildRefusalsListedAll`: a file with three independent refusable faults gives three refusals and no operation. `TestBuildWarnings`: `SalesRef` (`native`) gets the lock warning with "reinitialization"; a stopped distribution agent gets its warning; a concurrent subscription with a `distributor_status` 3 row names the log reader. `TestBuildAgentsToStart`: an added article on `SalesRef` lists the snapshot agent of `SalesRef` (`pending`) and the subscription (`delivery`). `TestBuildDeferredGenerationNote`: `SalesPub` with `immediate_sync_ready` false and every row at 2: no operation, the note. `TestBuildDeterministic`: two `Build`s of the same inputs marshal to identical JSON. `TestBuildPreconditions`: a table without a key refused with "14088"; a missing subscriber database refused; `Checks` nil: every precondition `unchecked`, no refusal; a server at major 15 refused with R18's text. `TestBuildSecrets`: a push subscription with `connection.security` `sql` and `password_secret` `SQLREPL_SQL_S_U` lists that secret once, set when `SecretSet` says so.
- [ ] Step 2: Run `go test -count=1 -v -run '^TestBuild' ./internal/plan`. Expected: compile failure, or failures on the lists not written yet (`TestBuildRefusesOutOfScope` of Task 10 shares the prefix: 11 tests run).
- [ ] Step 3: Implement.
- [ ] Step 4: Run the Step 2 command. Expected: 11 `--- PASS`. Then `go test ./...`.
- [ ] Step 5: Break step. Empty the R26 repair list: `TestBuildRepairsIncomplete` fails (a refusal where the snapshot agent was expected). Restore. Sort the operations by path only: `TestBuildOrderSteps` fails. Restore.
- [ ] Step 6: Commit.

### Task 16: T-SQL, summary and JSON

Files:
- Create: `internal/plan/render.go`, `internal/plan/render_test.go`, `internal/plan/testdata/create.sql`, `internal/plan/testdata/create.txt`

Interfaces:
- Produces:

```go
type Statement struct {
	Seq              int
	Server, Database string
	Text             string   // the batch: Prologue, then the EXEC; secrets as @secret_<n>
	Secrets          []string // the secret names, @secret_1 first
}
func (p *Plan) Statements() []Statement // one per operation, in Seq order; what apply executes
func (p *Plan) SQL() string             // Statements laid out as below
func (p *Plan) Summary() string         // the human summary
func (p *Plan) JSON() ([]byte, error)   // json.MarshalIndent(p, "", "  ")
```

- T-SQL layout: a header `-- server <name>` whenever the server changes from the previous operation; `USE <quoted database>;` whenever the server or the database changes; for each operation `-- <seq> <action> <kind> <path>: <costs>`, the R16 comment lines, the prologue when there is one, then `EXEC <procedure> <param> = <value>, ...;` on one line, parameters in `model.Parameters` order (identity first), flags last; `GO` never. Identifiers spliced into a `USE` are bracketed with `]` doubled.
- Summary layout, exact:

```
Plan for <publisher>.<database>: <n> operations, <c> costly.
  <seq>  <action> <kind> <path>: <cost>, <cost>
Totals: <cost> <n>, ...                     (costs in the order of spec "What a plan is", zero counts left out)
Refused:                                    (only when refused, then only the refusal lines and "Plan refused.")
  <path>: <reason>
Secrets:
  <NAME> set | <NAME> not set
Preconditions:
  <status> <name> <object>[: <detail>]
Agents apply will start:
  <kind> <publication>[ <subscriber>/<database>]: <reason>
Warnings:
  <text>
Notes:
  <text>
```

  An empty section is not printed; an empty plan prints `Plan for <publisher>.<database>: no changes.` and its sections.

- [ ] Step 1: Write the tests. `TestRenderSQLGolden`: the plan of `TestBuildOrderSteps`'s file renders exactly `testdata/create.sql` (written by the test once with `-update`, a flag of the test file, then reviewed by hand against this task's layout and committed). `TestSummaryGolden`: the same against `testdata/create.txt`. `TestRenderSecretsNeverValues`: with `SecretSet` returning true and the environment variable `SQLREPL_SQL_S_U` set to `p4ss!`, neither `SQL()`, `Summary()` nor `JSON()` contains `p4ss!`, and `SQL()` contains `@subscriber_password = @secret_1` and `-- @secret_1: secret SQLREPL_SQL_S_U`. `TestRenderQuotesNames`: a publication `a'b`, an article `x]y` and a subscription database `m sub]1` render `N'a''b'`, `N'x]y'`, `USE [m sub]]1];`. `TestPlanJSONRoundTrip`: `JSON()` unmarshals back into a `Plan` deep-equal to the original, the unexported `entry` and `Order` aside, and its top-level keys are `publisher`, `database`, `options`, `operations`, `refusals`, `warnings`, `notes`, `secrets`, `preconditions`, `agents_to_start`, `totals`. `TestRenderUseOnlyWhenDatabaseChanges`: three operations in `Sales` then one in `master`: two `USE` lines.
- [ ] Step 2: Run `go test -count=1 -v -run '^(TestRenderSQLGolden|TestSummaryGolden|TestRenderSecretsNeverValues|TestRenderQuotesNames|TestPlanJSONRoundTrip|TestRenderUseOnlyWhenDatabaseChanges)$' ./internal/plan`. Expected: compile failure.
- [ ] Step 3: Implement, write the golden files with `-update`, read them against the layouts above.
- [ ] Step 4: Run the Step 2 command (without `-update`). Expected: 6 `--- PASS`.
- [ ] Step 5: Break step. Render a secret parameter with the environment's value: `TestRenderSecretsNeverValues` fails, and its failure message must not print the value (it reports the offset only). Restore. Drop the `]` doubling in `USE`: `TestRenderQuotesNames` fails. Restore.
- [ ] Step 6: Commit.

### Task 17: Preconditions reader

Files:
- Create: `internal/precheck/precheck.go`, `internal/precheck/queries.go`, `internal/precheck/precheck_test.go`

Interfaces:
- Consumes: `state.Checks` (Task 8), `model.Config`.
- Produces:

```go
type Conns struct {
	Publisher   *sql.DB            // the publication database's server, master
	Distributor *sql.DB
	Subscribers map[string]*sql.DB // matched case-insensitively, as the reader's subscriberConn
	Unreachable map[string]string  // server name to the error that kept it out
}

// Run checks what the desired file relies on. It returns an error only for
// a failed read at a reached server; an unreachable server is a check.
func Run(ctx context.Context, c Conns, desired *model.Config) (*state.Checks, error)
```

- Queries, all `SELECT`, each one constant of `queries.go`: `qServer` (`@@SERVERNAME`, `SERVERPROPERTY('ProductVersion')`, `SERVERPROPERTY('ProductMajorVersion')`, `SERVERPROPERTY('Edition')`); `qTable` in the publication database (`OBJECT_ID(@p1)` of the quoted `schema.name`, whether a primary key exists in `sys.key_constraints`, the columns of `sys.columns` in `column_id` order); `qDatabase` at a subscriber (`DB_ID(@p1)` and `HAS_DBACCESS(@p1)`: a database the login cannot see is `Checked` false, never `Exists` false); `qFolder` at the distributor (`file_exists`, `file_is_a_directory` of `sys.dm_os_file_exists(@p1)`) for the distributor's `working_directory` and each `alt_folder`. A read the login is refused is an error, never an absence (spec "Inputs").

- [ ] Step 1: Write the tests. `TestPrecheckQueriesParse`: gated by `SQLREPL_TEST_DSN`, each query under `SET PARSEONLY ON` on a dedicated `sql.Conn`, as the reader's `TestQueriesParse` does. `TestSubscriberLookupIgnoresCase`: `Conns.Subscribers` keyed `repllab` serves `REPLLAB`. `TestLabPrecheck` (lab): for the fixture as desired, every `Sales` table exists with a primary key and its columns, `SalesSub` at the lab subscriber exists, a subscription to `m_nodb` reads `Exists` false and `Checked` true, the working directory exists, the server's `Major` is 16 and `Edition` contains `Developer`.
- [ ] Step 2: Run `go test -count=1 -v -run '^TestSubscriberLookupIgnoresCase$' ./internal/precheck`. Expected: compile failure.
- [ ] Step 3: Implement.
- [ ] Step 4: Run the Step 2 command (1 `--- PASS`), then `lab/gotest.sh '^(TestPrecheckQueriesParse|TestLabPrecheck)$' ./internal/precheck` (2 `--- PASS`).
- [ ] Step 5: Break step. Set `Checked` false whenever `DB_ID` is NULL: `TestLabPrecheck` fails on `m_nodb` (it expects `Checked` true, `Exists` false). Restore. Compare subscriber names exactly: `TestSubscriberLookupIgnoresCase` fails. Restore.
- [ ] Step 6: Commit.

### Task 18: The plan command

Files:
- Create: `internal/dotenv/dotenv.go`, `internal/dotenv/dotenv_test.go` (copied from `~/Sources/Repos/atelier/outils/sylloge/internal/dotenv/`, comments translated), `cmd/sqlrepl/plan.go`, `cmd/sqlrepl/plan_test.go`
- Modify: `cmd/sqlrepl/main.go` (the `plan` command in `main` and `usage`), `README.md` (a `plan` section)

Interfaces:
- Consumes: `model.Load`, `reader.Probe`, `reader.Read` (with `Facts: true`), `precheck.Run`, `plan.Build`, `serverFlags`, `openSubscribers`, `open`, `connParams` (existing CLI).
- Produces: `func runPlan(args []string, stdout, stderr io.Writer) error`, flags:

| Flag | Meaning |
|---|---|
| `-f PATH` | the desired file, required |
| `-server NAME=ADDRESS` | repeatable, as `export` (R29) |
| `-user`, `-param` | as `export`; the password from `SQLREPL_PASSWORD`, read after the `.env` load |
| `-env PATH` | the `.env` file, default `./.env`; absent is no error; the real environment wins |
| `-sql` | append the T-SQL to the summary |
| `-json` | print the plan as JSON only |
| `-defer-full-snapshot` | Options.DeferFullSnapshot |
| `-wait DURATION` | default `30m`; only checked against `-defer-full-snapshot` here |
| `-timeout DURATION` | default `2m` |

  Flow: load `.env`; `model.Load(-f)`; the publisher's address from `-server` by `publisher.server`, else the name; `reader.Probe` on master, `probe.Start()`; open the publication database; the distributor at the file's `distributor.server` address (by `-server`), else the probe's name; open every subscriber the file names (R29: a failure goes to `Unreachable`, not an error); `reader.Read`; `precheck.Run`; `plan.Build` with `SecretSet` = `os.LookupEnv` presence; print by R28. A `-server` entry that names no server of the file prints the note `note: -server %s names no server of the file` on stderr. A refused plan returns `errRefused`, which `main` maps to exit 1 after the output was printed.

- [ ] Step 1: Write the tests. The five copied `dotenv` tests, renamed nowhere (`TestParse`, `TestParseErrorNoEquals`, `TestLoadDoesNotOverride`, `TestLoadMissingFileNoError`, `TestLoadFilesPriority`). `TestPlanFlags`: `-f x.yaml -server a=b -sql -defer-full-snapshot -wait 5m` parses; no `-f` is an error naming it. `TestPlanRefusesWaitZeroWithDefer`: `-defer-full-snapshot -wait 0` reaches `Build` and returns `errRefused` (use a fake that stops after flag parsing: `runPlan` takes its connector through a package variable `connect` the test replaces). `TestPlanUnusedServerNote`: with `connect` faked, `-server other=x` prints the note. `TestLabPlanCLISalesEmpty` (lab, in `cmd/sqlrepl`): `runPlan` with `-f internal/testdata/lab/sales.yaml` (its path from the test's directory) and `-server` mapping the lab's `@@SERVERNAME` to `tcp:127.0.0.1,11980`, user `sa` from the DSN's password: returns nil and stdout's first line ends with `no changes.`.
- [ ] Step 2: Run `go test -count=1 -v -run '^(TestParse|TestParseErrorNoEquals|TestLoadDoesNotOverride|TestLoadMissingFileNoError|TestLoadFilesPriority)$' ./internal/dotenv` and `go test -count=1 -v -run '^(TestPlanFlags|TestPlanRefusesWaitZeroWithDefer|TestPlanUnusedServerNote)$' ./cmd/sqlrepl`. Expected: compile failures.
- [ ] Step 3: Implement.
- [ ] Step 4: Run the Step 2 commands (5 and 3 `--- PASS`), then `lab/gotest.sh '^TestLabPlanCLISalesEmpty$' ./cmd/sqlrepl` (1 `--- PASS`). Then `go build ./cmd/sqlrepl && go vet ./... && test -z "$(gofmt -l .)" && go test ./...`.
- [ ] Step 5: Break step. Let `.env` override a variable set in the environment: `TestLoadDoesNotOverride` fails. Restore. Return nil instead of `errRefused` on a refused plan: `TestPlanRefusesWaitZeroWithDefer` fails. Restore.
- [ ] Step 6: README `plan` section (flags, outputs, what is refused and why, the `.env`). Commit.

### Task 19: Convergence on the lab, creation and article changes

Files:
- Create: `internal/convergence/harness_test.go`, `internal/convergence/convergence_test.go`, `internal/convergence/testdata/setup.sql`, `internal/convergence/testdata/teardown.sql`, `internal/convergence/testdata/create.yaml`, `internal/convergence/testdata/add-article.yaml`, `internal/convergence/testdata/filter-change.yaml`, `internal/convergence/testdata/drop-article.yaml`

Interfaces:
- Consumes: `reader.Read`, `precheck.Run`, `plan.Build`, `model.Load`.
- Produces (test helpers, `harness_test.go`):
  - `labEnv(t, name string) *env`: skips without `SQLREPL_TEST_LAB`, fails without the DSN; runs `setup.sql` with `{db}` = `m_pdb_<name>`, `{sub}` = `m_sdb_<name>` (tables `dbo.m_t1 (id int PRIMARY KEY, a int, b int)`, `dbo.m_t2` and `dbo.m_t3` alike, 20 rows each with `a` from -9 to 10; the subscriber database empty); registers `teardown.sql` in `t.Cleanup` (each step in its own `TRY`: the pull subscriptions in the order of `08-pull P3.subscriber-first`, the push subscriptions with `@article = N'all'`, the publications, `sp_replicationdboption @dbname = {db}, @optname = N'publish', @value = N'false'`, then the two databases), then checks that no `m_pdb_<name>` or `m_sdb_<name>` database, publication or job is left.
  - `(e *env) desired(t, file string) *model.Config`: loads the file with `{server}`, `{db}` and `{sub}` replaced (the lab's `@@SERVERNAME`), and copies the lab's current `agent_profiles` into it (R6, R33).
  - `(e *env) plan(t, des *model.Config, opt plan.Options) *plan.Plan`: `Read` with `Facts`, `precheck.Run`, `Build`.
  - `(e *env) run(t, p *plan.Plan)`: executes each of `p.Statements()` on one pinned `*sql.Conn` per server, preceded by `USE` of its database, its secrets as named arguments `secret_<n>` read from the environment; on an error, reads `@@TRANCOUNT`, rolls back, and fails the test with the operation and the server's message. A `generate_and_wait` operation runs its call and then `e.waitDelivered`.
  - `(e *env) startAndWait(t, p *plan.Plan)`: `sp_startpublication_snapshot` for each publication in `AgentsToStart`, then `e.waitDelivered`.
  - `(e *env) waitDelivered(t, table string, want int)`: polls `SELECT COUNT(*)` of the subscriber table every second, up to 120 s.
  - `(e *env) converged(t, des)`: a new `plan` is `Empty()` after `startAndWait`; on failure the test prints `Summary()`.
- Scenarios. Every publication of these files has a snapshot agent on the never-firing schedule (`frequency: once`, `start_date: 99991231`) and the lab's distributor omitted (R4):
  - `TestLabSalesPlanEmpty`: read-only, no setup: the fixture `sales.yaml` against live `Sales` plans nothing (Review Focus 1). It never runs a statement.
  - `TestLabCreatePublication`: `create.yaml`, publication `m_p` (transactional, `native`, `independent_agent` true, `immediate_sync` false, `status: active`), articles `m_t1` with filter `a > 0` and procedure `m_flt1`, `m_t2` with `columns: [id, a]`, a push subscription to `{sub}` with `initialization: snapshot`. Asserts before running: the operations include, in order, `sp_replicationdboption`, `sp_addlogreader_agent`, `sp_addpublication`, `sp_addpublication_snapshot`, `sp_addarticle` (`m_t1`), `sp_articlefilter`, `sp_articleview`, `sp_addarticle` (`m_t2`), `sp_articlecolumn` (`b`, `drop`), `sp_articleview`, `sp_addsubscription`, `sp_addpushsubscription_agent`; no refusal. Runs, starts the snapshot, waits; data: the subscriber's `m_t1` holds the 10 rows with `a > 0`, its `m_t2` has the columns `id` and `a` only; then inserts `(100, -5, 0)` and `(101, 5, 0)` at the publisher and waits until the subscriber's `m_t1` has 11 rows, `101` among them and `100` not (spec "Testing", filters). Converged.
  - `TestLabAddArticle`: `create.yaml`, run, then `add-article.yaml` (adds `m_t3`): the plan has `sp_addarticle` without flag and one `sp_addsubscription @article = N'm_t3'`, cost `new_snapshot`; run, start, wait for 20 rows in `m_t3`. Converged.
  - `TestLabFilterChange`: `create.yaml`, run, delivered, then `filter-change.yaml` (`m_t1`'s clause `a > 5`): `sp_articlefilter` then `sp_articleview`, the reinit flag on the first (row at 2), cost `reinitialization`; run, start, wait; data: the subscriber's `m_t1` holds the rows with `a > 5` only (5 rows of the setup, plus `101` if inserted: this test inserts nothing). Converged.
  - `TestLabDropArticle`: `create.yaml`, run, delivered, then `drop-article.yaml` (without `m_t2`): `sp_dropsubscription @article = N'm_t2'`, then `sp_droparticle` without flag; the subscriber's `m_t2` still exists after the run (cost "subscriber object left behind"). Converged.

- [ ] Step 1: Write the harness, the files and the five tests.
- [ ] Step 2: Run, in one shell, `lab/gotest.sh '^(TestLabSalesPlanEmpty|TestLabCreatePublication|TestLabAddArticle|TestLabFilterChange|TestLabDropArticle)$' ./internal/convergence`. Expected: 5 `--- PASS`. A plan that does not converge is a defect of the planner or of a default: find which, fix the package, never the test's expectation. Then check the teardown left nothing: the count of `m_pdb_%` and `m_sdb_%` databases and of publications and jobs named with them is 0.
- [ ] Step 3: Break step. Make the articles strategy emit `sp_articleview` before `sp_articlefilter`: `TestLabFilterChange` fails on its data check or its order assertion (the view keeps the old clause, `14-filter-view F2b`). Restore. Make normalization's table `pre_creation_cmd` default `none`: `TestLabCreatePublication` fails to converge (one `sp_changearticle` planned). Restore.
- [ ] Step 4: Commit.

### Task 20: Convergence on the lab, publication-level strategies

Files:
- Create: `internal/convergence/strategies_test.go`, `internal/convergence/testdata/imm.yaml`, `imm-add.yaml`, `imm-schema.yaml`, `pull.yaml`, `properties.yaml`, `drop-publication.yaml`, `unmeasured.yaml`

Interfaces:
- Consumes: the harness of Task 19.
- Scenarios:
  - `TestLabImmediateSync`: `imm.yaml` (publication `m_pi`, `immediate_sync` true, `native`, `m_t1`, one push subscription), run, delivered (ready); `imm-add.yaml` adds `m_t2`: `sp_addarticle` with `@force_invalidate_snapshot = 1`, no extension; run, start, wait for 20 rows in `m_t2`; converged; then `imm-schema.yaml` changes `m_t1`'s `schema_options` (adds `nonclustered_indexes`): both flags, `reinitialization`; run, start, wait; converged.
  - `TestLabDeferFullSnapshot`: `imm.yaml` with `allow_anonymous: true`, run, delivered; `imm-add.yaml` with `Options{DeferFullSnapshot: true, Wait: 10 * time.Minute}`: the seven operations of `TestDeferSequence`; run (the harness's `generate_and_wait` waits for `m_t2`); the next plan has no operation and the note "full generation deferred"; converged.
  - `TestLabPullSubscription`: `pull.yaml` (publication `m_pp`, `allow_pull: true`, `independent_agent: true`, a pull subscription to `{sub}`): three subscription operations, two at the subscriber; run, start, wait; converged; then the file without the subscription: `sp_droppullsubscription` then `sp_dropsubscription`; run; converged.
  - `TestLabPropertiesAndSchedule`: `create.yaml`, run; `properties.yaml` changes `description`, `retention_hours` (100) and the snapshot agent's schedule (daily every 10 minutes, `start_date` 99991231 so that it never fires before the teardown): three `sp_changepublication` or `sp_changepublication_snapshot` operations, all `online`; run; converged; then `drop-publication.yaml` (no publication): the subscription dropped, then the publication; run; converged, and `publisher.log_reader_agent` is nil in the export (the last publication's drop removed it, R10).
  - `TestLabUnmeasuredRefused`: `create.yaml`, run; `unmeasured.yaml` changes the push distribution agent's schedule and the publication's `sync_method` to `concurrent_c`: two refusals, no operation, nothing run.

- [ ] Step 1: Write the files and the five tests.
- [ ] Step 2: Run, in one shell, `lab/gotest.sh '^(TestLabImmediateSync|TestLabDeferFullSnapshot|TestLabPullSubscription|TestLabPropertiesAndSchedule|TestLabUnmeasuredRefused)$' ./internal/convergence`. Expected: 5 `--- PASS`, and the teardown check of Task 19 gives 0.
- [ ] Step 3: Break step. Drop the snapshot flag from `add_article` (class `Online`): `TestLabImmediateSync` fails on the server's 20607 (the harness reports the operation, `@@TRANCOUNT` rolled back). Restore. Restore `immediate_sync` before `generate_and_wait`: `TestLabDeferFullSnapshot` fails on its order assertion. Restore.
- [ ] Step 4: Commit.

### Task 21: Documentation and the whole suite

Files:
- Modify: `README.md`, `CLAUDE.md`, `lab/README.md`

- [ ] Step 1: Update `CLAUDE.md`: status (plan 3 done; step 3 `plan` exists, step 4 not started); architecture (`internal/normalize`, `internal/cost`, `internal/plan`, `internal/precheck`, `internal/dotenv`, `internal/convergence`, `state.Checks`, the lab fixture); the traps found while building (each with its row); the rulings a later session must not undo without a measurement (R8, R9, R10, R15, R19, R26). `README.md`: `plan` (Task 18) completed with the cost vocabulary and the refusals. `lab/README.md`: the convergence tests, how they use the lab (`m_pdb_*`, `m_sdb_*`), and that they leave nothing.
- [ ] Step 2: Run the whole suite on the lab, in one shell: `lab/gotest.sh '.' ./...`. Expected: no `--- FAIL`, no `--- SKIP`. Then `go build ./cmd/sqlrepl && go vet ./... && test -z "$(gofmt -l .)" && go test ./...`.
- [ ] Step 3: Break step. Run `SQLREPL_TEST_LAB=1 go test -count=1 -v -run '^TestLabSalesPlanEmpty$' ./internal/convergence` without the DSN: it fails, it does not skip.
- [ ] Step 4: Stop the lab (`SHUTDOWN WITH NOWAIT` through `sqlcmd`), report `podman ps`. Commit.

## What plan 4 receives

- `plan.Build(Inputs, Options) *Plan`, pure, recomputed by `apply` before it runs; `Plan.Statements()`, one per operation in order, with its server, database, text and secret names: the text `apply` executes, with the R16 secrets bound as named parameters `secret_<n>`, and the text `-sql` prints.
- `Operation.Kind` `generate_and_wait` (R25), whose wait and report are plan 4's; `Plan.AgentsToStart` (R24); `Plan.Totals.Costly`, the count `apply` repeats in its confirmation.
- The ops `apply` adds around the plan (snapshot job disable and restore, `sp_start_job`) and their msdb permission precondition, the application lock, the deliveries owed, and the exit codes.
- `state.Checks` and `precheck.Run`, which `apply` reruns; `internal/dotenv` and `-env`.
- The lab harness of `internal/convergence`, whose `run` is a minimal executor that plan 4 replaces with `apply` and whose scenarios plan 4 reruns through it.
- Open: the remote distributor (R17), unmeasured agent schedule changes (R22), `lsn` initialization (R21), the shared pull agent (R21), every refusal of the cost table's "no entry" list, and the 2019 and 2025 replays (R18).

## Self-review

- Spec coverage. "Inputs": the three inputs (Tasks 4, 9), pending (R12, Task 9), the agent state warnings (R13, Task 15), out of scope against incomplete (R26, Tasks 10, 15), the empty configuration as a starting point (Tasks 14, 19). "What a plan is": operation fields and the ten costs (Task 8), plan-level lists (Task 15), outputs (Task 16, R28). "Costs and unmeasured changes": the cost table with rows (Task 7), refusal of the unmeasured (Task 10 `unmeasured`), flags exactly (R9), normalization tests as cost rules (Tasks 6, 15, 19). "Strategies": articles (Task 11), filters and views (Task 11), subscriptions (Task 12), publication properties and `-defer-full-snapshot` (Task 13), agents and profiles (Task 14), prediction (Task 9). "Order" (Tasks 9, 15 `TestBuildOrderSteps`). "The file": omitted properties (Tasks 2, 5, 6), not compared (Task 10), names (Task 6). "Shared distributor objects" (Tasks 4, 14). "Secrets" for plan (R16, Tasks 15, 16, 18). "Servers and connections" (R29, Task 18). "Engine as a library" (R1, `TestPurePackages`). "Blocking" warnings (Task 15). "Testing": unit tests per strategy and cost entry, lab convergence with data checks for filters and columns (Tasks 19, 20). Left to plan 4, named above.
- Unmeasured inputs found while writing, each given a measurement task before its consumer: reverse directions (Task 1, consumed by Task 7), destination owner and subscriber type defaults (Task 2, Task 5), profile changes (Task 3, Task 7). The rest stay refusals by "Only measured entries exist".
- Type consistency checked across tasks: `normalize.Refusal` aliased as `plan.Refusal`; `cost.Entry` attached as `Operation.entry`; `state.Checks` produced by Task 17 and consumed by Task 15; `strategies` filled by Tasks 11 to 14 in Task 10's order.
- Proportion: signatures, rules with their rows, and test assertions; no function body except the layouts that are exact copy.
