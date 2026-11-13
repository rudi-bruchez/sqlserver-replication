# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Go tool, `sqlrepl`, that manages SQL Server transactional replication as a declarative file, on the Terraform model: export the current state, diff it against the desired state, generate the `sp_add*` / `sp_change*` / `sp_drop*` calls. The tool replaces the configuration layer only; Microsoft's replication engine (log reader, distribution) stays.

Roadmap and status: step 1 (analysis, `docs/analysis/step-1-analysis.md`) and step 2 (read-only export) are done. The design of steps 3 and 4 is in `docs/superpowers/specs/2026-11-10-sqlrepl-plan-apply-design.md`; plan 1 (`docs/superpowers/plans/`, rename and measurement campaign) is done: the 2022 CU27 results in `lab/results/2022/` are those of commit `21c33a1`, its last measuring commit. Plan 2 (`docs/superpowers/plans/2026-11-11-sqlrepl-2-model-and-export.md`, model and export) is done: the model maps every parameter of the creation procedures, the export reads pull subscriptions, snapshot publications, every profile and, on request, the runtime facts, and an unconfigured database exports as the empty configuration. Plan 3 (`docs/superpowers/plans/2026-11-12-sqlrepl-3-planner.md`, the planner) is done: step 3, `sqlrepl plan`, exists and its convergence tests pass on the lab. Plan 4 (`docs/superpowers/plans/2026-11-12-sqlrepl-4-apply.md`, apply) is done: step 4, `sqlrepl apply`, exists, the convergence scenarios run through it, and the central scenario (`lab/fresh-apply.sh`: apply a file on an instance without replication, export, plan both empty) passes on 2022 CU27. Plan 5 keeps (R42): the snapshot report and `sqlrepl snapshot` with `-report` and `-sample-tail`, `apply -rotate-secret`, the windowed test of a generated and undelivered snapshot for `plan`, campaign items 15 to 18, the named instance, and the 2019 and 2025 replays. The export has run against the lab replication of `lab/README.md` (SQL Server 2022 Developer in podman), which found and fixed the command parsing and the filter procedure and sync view rules.

Scope: transactional and snapshot replication, push and pull subscriptions, SQL Server publisher. Merge, peer-to-peer, updatable and anonymous subscriptions, non-SQL Server subscribers and Oracle publishers are out of scope; the export reports them under `findings` (kind `out_of_scope`) instead of modelling them.

Everything written in this repository (docs, code, comments, commits) is in English.

## Commands

```
go build ./cmd/sqlrepl
go vet ./...
gofmt -l .
go test ./...
go test ./internal/decode -run TestParseCommand      # single test
```

`TestQueriesParse` (internal/reader) checks the syntax of every SQL query against a live instance and is skipped unless `SQLREPL_TEST_DSN` is set. No replication is needed. On the Windows machine the local instance is SQL Express with TCP disabled and SQL Browser stopped, so use shared memory; on Linux, the lab container:

```
SQLREPL_TEST_DSN='server=lpc:localhost\SQLEXPRESS;encrypt=disable' go test ./...
SQLREPL_TEST_DSN='sqlserver://sa:<url-encoded password>@127.0.0.1:11980?encrypt=disable' go test ./...
```

The lab tests (`TestReadLab*`) need the lab replication and run through `lab/gotest.sh FILTER PACKAGE...`, which builds the DSN from `MSSQL_SA_PASSWORD`, sets `SQLREPL_TEST_LAB=1` and redacts the password from the output. Load the password in the same shell command: `set -a; . <harness>/.env; set +a; lab/gotest.sh '^TestReadLabSales$' ./internal/reader`. It exits 3 when the filter matches no test.

The whole suite, lab tests included (562 tests, about sixteen minutes on 2022 CU27, most of it the convergence package's 876 s): `lab/gotest.sh '.' -timeout 60m ./...`, in the same shell as the password load. The script passes `-p 1`, which is required: the lab tests of `cmd/sqlrepl`, `internal/reader`, `internal/precheck`, `internal/apply` and `internal/convergence` share the lab, and run in parallel packages they deadlock on each other's drops and plan each other's objects in `Sales`; a failed reader test leaves its publication in `Sales` until its next run.

Running the export, the plan and apply:

```
sqlrepl export -publisher PUBSRV -database Sales [-distributor DISTSRV] [-server NAME=ADDRESS]... [-facts facts.json] [-o out.yaml]
sqlrepl plan -f desired.yaml [-server NAME=ADDRESS]... [-env .env] [-sql | -json] [-defer-full-snapshot [-wait 30m]] [-timeout 2m]
sqlrepl apply -f desired.yaml [-server NAME=ADDRESS]... [-env .env] [-auto-approve] [-defer-full-snapshot] [-wait 30m] [-timeout 2m]
```

`apply` exits 0 (nothing to do, or everything ran and every delivery owed is confirmed), 1 (an error, a refusal, the lock held, `Apply cancelled.`, a failed statement, operations left unrun), 2 (a usage error, no terminal without `-auto-approve`) or 3 (everything ran and a delivery is unconfirmed or not awaited, or the deferral's wait ended); `plan` exits 4 for a printed plan with a failed precondition (R52).

## Architecture

- `internal/decode`: pure functions between the coded values of the system tables (`schema_option` as big-endian `binary(8)`, article `type` and `status` bits, `pre_creation_cmd`, `ins_cmd`/`upd_cmd`/`del_cmd`, schedule codes…) and readable names. Invariant: unknown values are never dropped. They render as `unknown(n)` or as a hex bit, and the `*Code` / `Encode*` inverses accept them, so an export round-trips. Keep that invariant when adding a code table; step 3 relies on the inverses.
- `internal/model`: the YAML file format (`Config`, `FormatVersion` 2; `Load` refuses any other version). It holds configuration only, with no runtime state and no secrets: a password appears as a `password_secret` name, an environment variable name built by `SecretName` (`SQLREPL_<KIND>_<PART>...`, kinds `SQL`, `WIN`, `FTP`, `STORAGE`, every character outside `A-Z0-9` turned into `_`; a clash gets `_2`, `_3` and a `note` finding). Properties are pointers: nil means omitted, take the default, in a desired file; in a read configuration nil appears only where the type's `OmittedOK` allows it or a finding names the path (`TestReadLabExportsEveryProperty`). `Finding.Kind` is `out_of_scope` (plan 3 refuses the database), `incomplete` (a state to repair), `unreadable` (a value not to compare) or `note`. `Parameters` maps every parameter of the creation procedures (`field`, `creation_only` or `excluded`, with the first version that has it); `TestParametersCovered` checks it against each `lab/results/<version>/17-parameters.txt`.
- `internal/state`: the observed runtime facts (`Facts`: snapshot readiness and last generation, subscription status at the publisher and the distributor, agent jobs and history, profile uses, the template and default profile of each agent type). Never part of the YAML; written as JSON by `export -facts`. `Checks` holds the preconditions `precheck` reads; both cross from the readers to the pure planner here. Plan 4 added `JobPermissions` (`JobPermissionCheck`: sysadmin, `SQLAgentOperatorRole`, `ReadsJobs` on the three msdb tables, R55), `Agents` (`AgentServiceCheck`, `sys.dm_server_services`, R56), `LSNs` (`LSNCheck`, R57) and `Schemas` (`SchemaCheck`, R59).
- `internal/reader`: `Read(ctx, Source)` returns a `Result` (`Config`, and `Facts` only when `Source.Facts` is set: without it no facts query runs). It reads from the publisher (connected to the publication database), the distributor and the subscribers of `Source.Subscribers` (keys matched case-insensitively), where pull subscriptions are read. A probe through `master` first decides whether there is anything to read; otherwise the result is the empty configuration with a finding. `exporter.run()` reads in a fixed order (distributor, profiles, publications, articles, subscriptions, agents), and later steps depend on earlier ones (`pubIndex`, `articleNames`, `publisherID`). All SQL is in `queries.go`. `{dist}` and `{servers}` are substituted by `distQuery`: the quoted distribution database name, and `MSreplservers` or the `fallbackServers` derived table for distributors older than 2016 SP2 CU3, decided by reading the table (`replServersExist`: error 208 is absence), never from what the login can see nor from the version (a Managed Instance reports 12.0).
- `internal/normalize`: the measured defaults table (`lab/results/2022/11-defaults.txt` rows) and `Normalize`, which fills every omitted property of a desired file in its context (publication type, `sync_method`, article kind) or refuses it.
- `internal/cost`: the cost table, one entry per property change or structural operation, keyed by R8, with the class that decides the flags (R9) and the rows it cites; `TestCostTableMatchesRows` checks every cite against the results files. A change `Lookup` does not find is refused as not measured.
- `internal/plan`: the planner. `Build(Inputs, Options) *Plan` is pure (normalize, diff, strategies in a fixed order, state prediction, job operations, finish); `Plan.Statements()` gives one statement per operation, the text `apply` will execute and `-sql` prints, secrets as `@secret_<n>`. For apply (plan 4 Task 4) the plan also carries `Operation.Owes` and `OwesAt` (`before`, `after`, `marked`), `Plan.OwedBefore`, `DistributionDB`, `SnapshotRoots` and `SnapshotRootsBefore`, and `SnapshotJobs` read through `SnapshotJobLookup(publication)`, the prologue that declares `@job_id` (R62); `JobIdle` is exported, a `job_start` ends with `SELECT @started AS started`, and the `-sql` header says apply may run a `job_start` again (R51). `normalize`, `cost` and `plan` import neither `database/sql` nor the reader nor `precheck` (`TestPurePackages`).
- `internal/precheck`: `Run` reads the preconditions into `state.Checks` (servers reached with `@@SERVERNAME`, version and edition; source tables and their columns and keys; subscriber databases; snapshot folders, the distributor's current `working_directory` when the file omits it; profiles at the distributor, 208 read as no profile; the msdb job permission and SQL Server Agent at the distributor and every subscriber; the LSN of an `initialize from lsn` subscription against `restorehistory` and the log end). `Run(ctx, conns, desired, current)`. The planner never reads a server itself.
- `internal/apply`: `Run(ctx, Target, Options) (*Result, error)` runs a plan (R43 to R62). It imports `plan` and `state`, never `reader` nor `precheck`: the CLI and the harness wire them through `Target.Plan`. `session.go` pins one `*sql.Conn` per server and executes `Statement.Text` byte for byte, then reads `@@TRANCOUNT`; `classify.go` holds the error classes, `driverError` (skips Msg 266), the 18752 re-reads (`effectQuery`) and `mask`; `lock.go` the application locks; `jobs.go` the disables, idle waits, restores on every way out and starts; `deliveries.go` and `folders.go` the deliveries owed and their confirmation; `result.go` the outcome, the question, the output lines and `ExitCode`; all SQL in `queries.go` (`TestApplyQueriesParse`). The only writes are the plan's statements, the `ROLLBACK` of a transaction a refused call left, and the locks (anti-goal 2).
- `internal/dotenv`: the `.env` loader of `-env`, copied from atelier's sylloge; the real environment wins.
- `internal/convergence`: lab tests only (`lab/README.md`, "Convergence tests"), each on its own `m_pdb_<test>` and `m_sdb_<test>`; the scenarios run through `apply.Run` (`e.apply`, R60), and the old minimal executor `run` stays for `jobstart_test.go` alone. `apply_test.go` holds the apply scenarios of plan 4 Task 12.
- `internal/testdata/lab`: the lab fixture, `sales.yaml` (the export of `Sales` without schedule start dates, R37) and `sales-facts.json` (capture-time facts, a frozen unit input); the plan of `sales.yaml` against the live lab is empty.
- `cmd/sqlrepl`: flag parsing and DSN building (`host\instance,port`, optional `lpc:`/`np:`/`tcp:` prefix mapped to the go-mssqldb `protocol` parameter; Windows authentication when no `-user`); `plan` opens the publisher, the distributor and every subscriber once, runs the read and `precheck.Run`, then `plan.Build`; `apply` checks the terminal, opens the same pools, maps them to `apply.Servers`, prompts, catches `SIGINT` and `SIGTERM`, and maps the `Result` to the exit code.

Traps already paid for, documented at the queries:

- Read `syspublications`, `sysarticles`, `syssubscriptions` in the publication database. The distribution database has views with the same names that only cover Oracle publishers.
- Virtual subscribers have `srvid` / `subscriber_id` < 0 and must be filtered out.
- The distributor linked server at the publisher is always named `repl_distributor`; the real instance is `sysservers.datasource`.
- A shared distribution agent is stored with `publication = N'ALL'`. It is exported once, under `publisher.shared_distribution_agents`.
- `job_id` in the replication tables is `binary(16)` and can outlive a deleted job.
- `SET PARSEONLY` only affects the batches after it in the same session; the test sets it on a dedicated `sql.Conn`.
- `MSsnapshot_agents` has a row for every publication, `local_job = 0` and a never-created `job_id` when `sp_addpublication_snapshot` was not called.
- Server names differ in case between tables (`syssubscriptions.srvname` is upper case, `@@SERVERNAME` is not): compare them case-insensitively.
- The article `type` does not tell a user-named filter procedure or sync view; see `lab/README.md` for what does.
- The synchronization view `sp_articleview` writes has one exact form, on one line (`create view [s].[v]as select [c1],[c2]  from  [s].[t]  where HAS_PERMS_BY_NAME(...)= 1  and (<clause>)`). `checkSyncView` reads it by position, since a clause can contain `= 1` and a bracketed name `from` or `,`; any other text is a user's own view, not checked.
- `MSsubscriptions` has rows for the publication's virtual subscribers (`subscriber_id` -1, -2) whose window moves at every run. Read only each subscription's own rows (`subscriber_id >= 0`, joined to `MSpublications` and `MSarticles` on publisher id, database and ids, the subscriber named through `{servers}`, whose ids differ from the publisher's `srvid`). Status 3 is read there, never in `syssubscriptions`.
- A pull subscription is read at its subscriber with the join of `sp_helppullsubscription` (`MSreplication_subscriptions` left joined to `MSsubscription_properties` on `UPPER(publisher)`, `publisher_db`, `publication`). Do not filter on `subscription_type`: the unique index includes it, so an anonymous row (type 2) can stand beside the type 1 row, and it must be reported. `independent_agent` and `immediate_sync` at the subscriber are parameters that default to 1, not copies of the publication's.

## Traps of the planner

Met while building plan 3, each measured on 2022 CU27; the source is a campaign row or the plan 3 review that measured it (`docs/analysis/replication-oddities.md` has the detail and the traps that do not bite code).

- A refused replication call can leave `@@TRANCOUNT` higher than before, with `@@ERROR` 0 right after the `EXEC` (Task 7 review; R39's 21805 and 245): roll back after any refused call.
- A `sp_change*` `@value` is an `nvarchar` literal whose form depends on the property: `N'0x...'` for `schema_option` (a bare literal is 21805), `N'0'`/`N'1'` for `replicate_ddl` (`N'false'` is 245); at creation `sp_addpublication @replicate_ddl N'false'` is 8114 (R39, Task 8 review).
- `sp_addpublication`, `sp_addlogreader_agent`, `sp_addsubscription` and `sp_addpushsubscription_agent` start agent jobs at once, even for an unreachable subscriber (Tasks 5 and 14 reviews, `O13`).
- `sp_addpushsubscription_agent` on an existing shared agent drops and re-creates its job (new `job_id`, history lost, re-enabled, started): never call it when the shared agent exists. Dropping the last push subscription of a shared agent drops the agent and its job; dropping by name every article of a subscription drops the subscription and its agent (Task 12 review).
- `sp_droparticle` drops the article's synchronization view, a user's own included; `sp_articleview` creates the view in `dbo` whatever `@view_name` says, while `sp_articlefilter` honors a schema in `@filter_name`; `sp_changearticle sync_object` to a missing view is 15001 (Tasks 8 and 11 reviews).
- A re-add or reinitialization over a subscriber table whose article has `pre_creation_cmd` none and which holds the rows fails 2601 then 20253 and retries forever (Task 13 review): the plan warns.
- 18752 from `sys.sp_replcmds` or `sp_repldone` during `sp_droppublication`, `sp_articlefilter` with the reinit flag, `sp_replicationdboption publish false` right after the last drop, and `sp_changepublication sync_method` with the log reader running: the call often completes all the same, and go-mssqldb returns it as an error (`O14`, Tasks 11, 16 and 20).
- `sp_startpublication_snapshot` while the job runs or has a pending request returns 22022, class 16, an error to go-mssqldb; `sp_start_job` on a running or just-started distribution job also returns 22022 (Tasks 15 and 19).
- A pull agent's job has no schedule; started before the generation has ended, it runs once and exits without delivering (Task 15 review).
- `[` and `]` in a publication or article name are 15006 (`sp_MSreplcheck_name`); the default commands of a table with `]` in its name store it doubled (Task 16 review).
- Several calls, each with its own `DECLARE`, in one batch fail Msg 134 at compile: one batch per operation (Task 16 review).
- `sp_drop_agent_profile` on an in-use default fails 20065 but leaves two defaults for the type; `sp_add_agent_profile @default = 1` rebinds no existing agent (Task 14 review).
- `sp_changedistributiondb` refuses a `max_distretention` below the current minimum, or a minimum above the maximum, with 14107: order the two calls (Task 14 review).
- `sp_changepublication_snapshot` with only the four frequency fields keeps the stored end time and relative interval; `sp_addpublication_snapshot` without a schedule creates daily every 5 minutes (Tasks 14 and 15 reviews).
- `sp_changepublication sync_method` rewrites neither `dest_owner`, nor `schema_option`, nor the commands of the articles (Task 20 review).
- A push subscription writes a `MSreplication_subscriptions` row (`subscription_type` 0) at the subscriber, on which `sp_droppullsubscription` fails (Task 19).
- `sp_addsubscription` of a pull subscriber with no such host adds it to `sys.servers`, `MSreplservers`, `MSsubscriber_info` and `MSsubscriber_schedule`; no procedure removes the `MSreplservers` row (Tasks 4 and 18; `M_FRESHSUB` and two `RV_*` rows were such residue on the lab until `lab/start.sh` recreated it in plan 4 Task 13, which left `MSreplservers` with the lab's own row only).
- Precheck: `HAS_DBACCESS` is NULL for a missing database and 0 for one the login cannot use or that is OFFLINE or RESTORING, even as `sa`; database-level `VIEW DEFINITION` stays 1 under a schema or object `DENY`; `SELECT TOP (0)` tells missing (208) from hidden (229), but a view over a dropped table gives 208 then 4413 and the driver keeps the last number (Task 17 reviews).
- go-mssqldb: `PingContext` ignores its context while a silent listener withholds the prelogin; the `connection timeout` parameter bounds it, and a key written with spaces is ignored (Task 18 review).
- On a Linux distributor the distribution agent cannot apply a snapshot with pre- or post-snapshot scripts (registry lookup of the SQL utilities path, `18-reverse` setup): the plan warns.

## Traps of apply

Met while building plan 4, on 2022 CU27; each with its row or test (`docs/analysis/replication-oddities.md` has the detail).

- SQL Server Agent stopped refuses `sp_start_job` and `sp_startpublication_snapshot` with 22022, the busy number, and go-mssqldb returns it as an error even inside `TRY...CATCH`; tell them apart by "SQLServerAgent is not currently running", never "running" alone, and classify before reading `started`: on any 22022 the R62 batch delivers no row (`agent-stopped AS.start_job.stopped`, `TestClassify`, `TestStartOutcome`).
- A bound batch runs through `sp_executesql`, and a refusal that leaves `@@TRANCOUNT` changed adds Msg 266 after the real error; the driver reports 266, the real number is in `All`: read the first entry that is not 266 (`driverError`), and take 266 alone with an open transaction as a success that left one (`TestLabSecretRefusalNumber`).
- A statement cancelled by its context leaves its `*sql.Conn` bad ("driver: bad connection"): probe and take a new connection before the restores (`TestLabCancelDuringStatement`).
- An application lock belongs to the database it was taken in: `sp_releaseapplock` from another one is 1223 and the lock stays. `sql.Conn.Close()` pools a session with the lock held; `conn.Raw` returning `driver.ErrBadConn` ends it. Check a discarded session by `connection_id`, not `@@SPID`, which is reused within the second (`TestLabAppLock`, `TestLabUnlockFailureDiscards`, `TestLabCloseAfterKill`).
- The distributor lock taken in the distribution database fails 911 when the plan creates it: it lives in `master` (R45a, `TestRunDistributorLockInMaster`, `fresh-apply FA.apply`).
- `msdb.dbo.MSagent_profiles` does not exist before the instance is a distributor: 208 is no profile (`TestReadProfilesNotDistributor`, `fresh-apply`).
- `SQLAgentOperatorRole` runs `sp_update_job` and `sp_start_job` but gets 229 on `sysjobs`, `sysjobactivity` and `syssessions`, which the job prologue and `JobIdle` read: `ok` needs sysadmin, or an operator with `ReadsJobs` (granted case unmeasured) (`20-apply AP.perm.*`, `TestBuildJobPreconditions`).
- A disabled snapshot job's schedule starts no run, but `sp_start_job`, the guarded `job_start` included (`started` 1, `enabled` still 0), and `sp_startpublication_snapshot` start a disabled job (`20-apply AP.disabled_schedule`, `AP.enabled_schedule`; Task 7 review probe D).
- A lock on one job's `sysjobs` row blocks `sp_update_job` of every job of that server: n restores at a blocked server take n times `-timeout` (Task 7 review probe E). A connect to a listener that withholds the prelogin is bounded only by the driver's `connection timeout` (`TestRestoreBoundSilentServer`).
- The distribution database is case-insensitive (`SQL_Latin1_General_CP1_CI_AS`): R61's lookup of a dropped `SalesRef` finds a new `SALESREF`'s job, so R61 restores sort before every other restore (`TestDroppedRestoreBeforeOtherRestores`).
- `initialize from lsn` needs `allow_initialize_from_backup`, else 18786 (`20-apply AP.lsn.no_backup_flag`). The last `restorehistory` row is not where the database stands after a `STOPAT` restore, survives a `DROP DATABASE`, and keys on the destination name (a renamed restore reads an older row, a known limit); compare `sys.database_recovery_status.family_guid` with the backup's, not `create_date`, which is 7 to 10 ms after `restore_date` on a valid restore (`TestLabRestoreHistoryLSN`, `TestCheckLSN`).
- `sys.dm_os_enumerate_filesystem`: `level` counts from the children of the folder listed, so match `parent_directory` (with its trailing `/` on Linux) and `full_filesystem_path`, never a level; a missing folder lists 0 rows and no error; a folder the server cannot read still appears as its parent's child (`21-deliveries DL.listing`, `TestRunFolders`, `TestNoRunYet`).
- Snapshot folders are `<PUBLISHER>_<DATABASE>_<PUBLICATION>` upper-cased and not unique by suffix (`x_m_db_m_p` ends like `m_p`): match the whole name without regard to case (`TestPubFolderIdentified`). `MSdistpublishers.name` stores `REPLLAB` against `@@SERVERNAME` `repllab` (`TestListReadsPublisherRoot`).
- `MSdistribution_history` has no `id`: a row is `(agent_id, timestamp)`; take T with `GETDATE()` at the distributor (`time` is `datetime`); a rowversion printed as text goes through `binary(8)` first. The agent lookup returns the subscription's own agent and a shared `N'ALL'` agent of the same subscriber database, whose lines name other publications' folders (`21-deliveries`, `TestConfirmGates`).
- A pull agent writes its "Delivered snapshot" line in the distributor's history (`DL.pull.delivered_line`). An `S7` subscription can receive the run listed at T (`DL.s7_frequent`). A shared agent kept across a drop and re-add keeps its row and job, only the mark separates the incarnations (`DL.shared_readd_kept`).
- A replication support only subscription is never reinitialized (`sp_reinitsubscription` refuses "no sync", the status stays 2): owed nothing (`TestReinitSkipsReplicationSupportOnly`).
- `sp_reinitsubscription` with the log reader running can return 18752 and mark the subscription all the same (`TestLabApplyOwedBefore`).
- `sp_articlefilter` stores the clause verbatim, `N''` like NULL; under the CI collation a case-only clause change compares equal, so the 18752 re-read compares in `Latin1_General_BIN2` (`TestEffectQueryCovers`).
- Msg 245 echoes a value raw and Msg 2628 a prefix of it: `mask` replaces whole values only, a truncated prefix survives (`TestMaskSecrets`).
- `/dev/null` on standard input is a character device: it passes R44's terminal test and ends `Apply cancelled.`, exit 1, not 2 (Task 10 review; open question for Rudi).

## stored-procedures/

Source of the SQL Server 2019 replication system procedures, as a reference, not part of the build. The public procedures (`sp_changearticle`, `sp_addarticle`, `sp_help*`…) are thin wrappers around `sys.sp_MSrepl_*`, whose code is not in the folder. The rules for snapshot invalidation and reinitialization therefore cannot be read here. The distributor-side procedures (`sp_MShelpsnapshot_agent`, `sp_MShelp_subscription`, `sp_MSenumdistributionagentproperties`, `sp_MShelp_profile`) are real queries and show the correct joins.

## Cost and flag rules

The impact matrix (which property change needs `@force_invalidate_snapshot` or `@force_reinit_subscription`) is measured on the lab (`lab/campaign/02-matrix.sql`, section 5 of the analysis document), and the campaign of `lab/campaign/` measures the rest the planner needs (results in `lab/results/2022/`, one section per script in `lab/README.md`). Microsoft Learn was wrong on several entries (commands and `status` change online; `sp_articlecolumn` works on a subscribed article; the list is in section 5 of the analysis document). The snapshot flag is asked exactly when `immediate_sync_ready = 1`, and the reinit flag when the operated article's subscription is at status 2, or for `sync_method` any article (`05-snapshot-flag`, `S6.O6`). `sync_method` needs a reinitialization only for a change from or to `concurrent` or `concurrent_c`, which marks every subscription; between `native`, `character` and `database snapshot` it marks nothing (`15-snapshot-scope`, rows `C.*.sync_method` and `D.*.sync_method_probe`). Take the plan logic from the measured tables and the rows the design cites, not from Learn. The structural operations (adding an article with and without `immediate_sync`) and the traps of apply (a refused call leaves its transaction open) are measured too, `lab/README.md` rows 9 to 12.

Oracles for verification: `Export-DbaReplServerSetting` (dbatools, wraps RMO `ReplicationServer.Script()`) for the export, and RMO with `SqlExecutionModes.CaptureSql` for generated T-SQL.

## Rulings

Rulings of plan 3 that a later session must not undo without a measurement. The numbered ones are in the plan's "Rulings" section, with their reason and their cost if wrong.

- R6 profiles: a new profile copies its type's template (`MIN(profile_id)` system profile), then one call per parameter; a change of `default` on an existing profile is refused; a profile absent from the file is dropped only when no use remains. An omitted `agent_profiles` key means profiles are not managed (no profile operation); `[]` means managed and empty, and the export writes `[]` once the distributor has been read (`32bdd9d`). A profile created in the plan costs online unless it is made the default (`@default = 1`); the default an omitted `profile` takes is the desired `default: true`, else the kept current default, else the template; two desired defaults of a type are refused.
- R8 cost keys (path pattern, publication type, direction, `sync_method` pair); R9 the flags exactly from the predicted state; R10 the state prediction (amended: `backup` and `lsn` rows start at 2 and start the agent, `10-init-modes I2.backup.create`); R15 a creation call passes a parameter only when it differs from its context's default; R19 the measured `sync_method` pairs, every other one refused.
- R26 findings: `out_of_scope` refuses, `unreadable` is not compared, `incomplete` is repaired only by the measured rules (a missing job of a snapshot agent or log reader the plan does not repair is refused).
- R34 structural costs, one article counted once; R35 a subscription missing articles is refused, not completed with `@article = N'all'`; R36 every extension passes `@subscription_type` and `@sync_type`; R37 zero schedule start dates are not compared nor passed; R38 declared schedule end defaults, `enabled` not settable; R39 change-call literals per (procedure, property).
- Omitted sync_method-dependent article properties (`destination.schema`, `ins_cmd`, `upd_cmd`, `del_cmd`): an existing article keeps its current value only when it equals the creation default of some `sync_method` of its group; otherwise, and for a new or re-added article, the desired context's default (spec "Omitted properties", `07351cb`).
- Identifiers (columns, articles, source, procedures, profile parameter keys, server names) compare without regard to case; the diff path of a matched pair uses the current key.
- Servers: `Build` refuses a reached server whose `@@SERVERNAME` differs from the file's name, compared without regard to case; every server an operation runs at needs a `ServerCheck`, and a missing one is unreachable (R29). `-timeout` bounds each connection through the driver's `connection timeout`, unless `-param` sets one. `-defer-full-snapshot` with `-wait <= 0` is refused before connecting.
- `[` and `]` are refused in publication and article names (15006).
- Secrets are numbered once per plan, in order of first use, the same name keeping its number; `-sql` prints one batch per operation and no `GO`.
- When normalization refuses, `Build` runs no strategy. Snapshot-publication subscription and agent defaults are not measured: omitted ones are refused there. An existing snapshot publication is not edited structurally (articles, filters, views) until a campaign row measures it.
- Omitted instance-dependent distributor values (data and log folders and files, `working_directory`) and a pull agent's `@distributor` are not passed at creation and not compared. An omitted command is its mode with no procedure name (the generated name is unpredictable past 109 characters). A declared schedule passes every frequency field at creation; `subday` "" normalizes to `at_time`.
- A pre- or post-snapshot script gets the Linux warning; a `sync_object` change is refused when the view is `sp_articleview`'s; `-defer-full-snapshot` is refused with a `sync_method` change.

Rulings of plan 4, in that plan's "Rulings" section:

- R45 the lock `sqlrepl apply` on the publisher's pinned session in the publication database, before the read, held through the prompt, released after the restores on every way out, a failed release reported and the session discarded; R45a the distributor lock `sqlrepl apply distributor` in `master` on the distributor, when the file declares `distributor` or `agent_profiles`, and a shared operation without it refused.
- R46 one pinned connection per server, statements as printed, `@@TRANCOUNT` read after each (the push subscription unit excepted) and rolled back as a failure; reads, rollbacks and restores under a fresh context bounded by `-timeout`.
- R47 the error classes: 22022 busy only on snapshot starts and `job_start`, 21854/21861 wait idle then one retry by `retryDecision`, 18752 tolerated only on the measured procedures and only after the re-read shows the change, 1205 and others stop.
- R48 a restore armed before each `job_disable` is sent, an idle wait after it, every armed restore run on every way out (one reconnect and retry each, each bounded by its own `-timeout`), a second signal ignored.
- R49 snapshot starts compare no clock: `started` from the guarded batch, a skipped start waited out and rerun only when still pending.
- R50 deliveries owed: T and the mark at the distributor, the listing at T of every root (`SnapshotRoots`, `SnapshotRootsBefore`), a run absent at T, a run in progress at T refused by retaking the record once idle, the folder matched by its whole name; R50a a publication with no folder in any listing that shows `unc` has no run yet; R50b an omitted root read from `MSdistpublishers` when the record is taken.
- R51 a distribution or pull `job_start` runs after the generation its delivery waits for, once more if its job ended first; the deferral's starts, then its wait for deliveries before `immediate_sync` is restored (kept although the lab showed no harm from the reverse order).
- R52 `-wait` bounds the generations and deliveries, `-timeout` the operation's own waits; the exit code table. A lost lock does not change the exit code; a job left disabled makes it 1.
- R55 `msdb job permission` and R56 `sql server agent` preconditions; R57 the LSN check (zero, beyond the log end, equal to the last restore's `last_lsn`, no `STOPAT`, matching `family_guid`), pull from LSN refused; R58 apply refuses a failed precondition, and an unchecked one of R55 or R56 where it runs a job operation.
- R61 a dropped publication's guarded `job_restore`, sorted before the other step 12 restores; R62 `SnapshotJobLookup` and the `job_start` that returns `started`.
- The state prediction marks no replication support only subscription on a reinit; backup and lsn are left as they are (unmeasured).

## Before plan 5

Plan 5 receives:

- `apply.Run` with its `Result`, the deliveries it confirms (`Delivery`), and its waits, which `sqlrepl snapshot` reuses for one publication; the R53 output lines, which the report extends rather than replaces.
- `Operation.Owes`, `OwesAt`, `Plan.OwedBefore`, `DistributionDB`, `SnapshotRoots`; the queries of `internal/apply/queries.go`.
- The rows of `20-apply`, `agent-stopped`, `21-deliveries` and `fresh-apply`.

Open: the report and `-sample-tail` (R42), `-rotate-secret`, the windowed test of a generated and undelivered snapshot for `plan`, campaign items 15 to 18, the named instance (its snapshot folder form is not measured: apply reports its deliveries unconfirmed), the remote distributor (R17), the 2019 and 2025 replays (R18), and the spec's line 119 on dropping another database's unused profile. Still open from plan 3: agent schedule changes other than the snapshot agent's (R22), the extension of `backup` and `lsn` subscriptions and the shared pull agent (R21), the completion of a subscription missing articles (R35), a change of a profile's `default` (R6), and every refusal of the cost table's "no entry" list.

Parked during plan 4, open:

- An unreadable `unc` folder counts as no run: no false confirmation, but the delivery waits the whole `-wait`.
- The refusals of an LSN above or below the restore's `last_lsn` are unit-tested only (`TestCheckLSN`).
- A misspelled profile on a plan that creates the distributor fails mid-plan, not up front: precheck cannot read the profiles of a distributor that does not exist yet.
- The snapshot folder precondition is not checked when `working_directory` is omitted at the creation of the distributor (`sp_adddistpublisher` refuses a missing folder itself, 21037).
- `/dev/null` on standard input exits 1, not 2 (R44's character device test); an operator granted `SELECT` on the three msdb tables is `ok` by R55 without a measurement; the `{servers}` fallback of the agent lookup returns no row on the lab and is unproven.
