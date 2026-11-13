# sqlserver-replication
Improving and managing SQL Server replication

## Contents

- `stored-procedures/`: source of the SQL Server 2019 replication system procedures, for reference.
- `docs/analysis/step-1-analysis.md`: where the replication configuration lives, how to decode it, and which changes invalidate the snapshot or reinitialize subscriptions.
- `cmd/sqlrepl`: a tool that manages transactional replication as a declarative file: export, plan and apply.

## sqlrepl export

Reads a publication database, its publications, articles, push and pull subscriptions and agents, and writes them as YAML. It only runs `SELECT` statements, on the publisher, on the distributor and on the subscribers given with `-server`.

Scope: transactional and snapshot replication, push and pull subscriptions, SQL Server publisher. Anything else found (anonymous and updatable subscriptions, peer-to-peer, non-SQL Server subscribers) is reported under `findings`. Each finding has a `kind` (`out_of_scope`, `incomplete`, `unreadable` or `note`), the `path` of the element concerned and a `message`.

Besides the publications, the file holds the distributor properties (cleanup batch sizes, the folders and names of the distribution database files, the security of the `repl_distributor` link, `multi_subnet_failover` and, on SQL Server 2025, the link's `Encrypt`, `TrustServerCertificate` and `HostNameInCertificate` settings when they are set), the publisher's `sync_with_backup`, and per publication the partition switch options, `enabled_for_het_sub`, `snapshot.enabled_for_internet` and the `type` and `subscriber_type` of each subscription. A property the export could not read is left out and has a finding.

A pull subscription's agent runs at the subscriber, which keeps its settings and its job. The export reads it under `pull_agent` when the subscriber is given with `-server NAME=ADDRESS`, `NAME` being the subscriber name as the publisher records it, in any case. Without it, `pull_agent` is left out with an `unreadable` finding that names the flag to pass. The pull subscriptions of one subscriber database to publications without an independent agent share one agent, exported once under `publisher.shared_pull_agents`. The subscriber connection uses the publisher's credentials (`-user`, `-param`).

```
go build ./cmd/sqlrepl
sqlrepl export -publisher PUBSRV -database Sales -o sales.yaml
sqlrepl export -publisher PUBSRV -database Sales -server SUBSRV=subsrv.example.com,1433 -o sales.yaml
```

Options:

| Option | Meaning |
|---|---|
| `-publisher` | publisher instance: `host`, `host\instance`, `host,port`, optionally prefixed by a protocol (`lpc:`, `np:`, `tcp:`) |
| `-database` | publication database |
| `-distributor` | distributor instance; by default, the distributor registered at the publisher, looked up first among the `-server` names |
| `-publisher-name` | publisher name registered at the distributor, when it differs from `@@SERVERNAME` (publication database in an availability group) |
| `-user` | SQL Server login, password in `SQLREPL_PASSWORD`; Windows authentication by default |
| `-param key=value` | extra go-mssqldb connection parameter, repeatable (`-param encrypt=disable`) |
| `-server NAME=ADDRESS` | address of a server by its name, repeatable: each one is opened as a subscriber whose pull subscriptions are read, and the distributor name registered at the publisher is looked up among them; the address takes the `-publisher` forms. A name given twice, in any case, is an error |
| `-o` | output file; standard output by default |
| `-facts PATH` | also write the observed runtime facts as JSON to `PATH` (below); without it nothing about them is written and the YAML is unchanged |

Required permissions: read access to the publication database, and to `msdb` and the distribution database on the distributor (`SELECT` on `MSreplservers` included); for a pull subscription, to the subscription database and `msdb` on the subscriber. A faithful export also needs, at the publisher, `ALTER ANY LINKED SERVER`, without which `sys.servers.provider_string` reads NULL for `repl_distributor` (`multi_subnet_failover` and the `link_*` settings; its login mappings in `sys.linked_logins`, for `admin_link_security`, are also shown by `VIEW ANY DEFINITION`), and `VIEW ANY DEFINITION` or an equivalent: at the distributor for `sys.master_files` (the folders and files of the distribution database; `CREATE DATABASE` or `ALTER ANY DATABASE` also show them), at the publisher for the names of filter procedures, the definitions of synchronization views and the source object of a schema-only article (a procedure, view or function, hidden under `db_datareader`) (`VIEW DEFINITION` on the publication database is enough). Without them the export still runs and reports each value it could not read as `unreadable`, naming the path; it never writes a hidden value as absent. A login that cannot read `MSreplservers` or `MSpub_identity_range` at all gets an error for the first and an `unreadable` `identity_range_management` for the second.

Passwords are never exported. Where an agent uses SQL Server authentication, the file carries a `password_secret` name instead: the name of the environment variable that will provide the password at apply time, `SQLREPL_<KIND>_<PART>...` (`SQL` with the server and the login, `WIN` with a job account, `FTP` with the address and the login, `STORAGE` with the publisher), upper case, every character outside `A-Z0-9` replaced by `_`. Two agents that use the same login on the same server share one name; two different sources that sanitize to the same name get `_2`, `_3` and a `note` finding. Agent command lines are exported with their password arguments masked.

### File format

The file starts with `version: 2`; a file of another version is refused when read. Every property is optional: in a file written by hand, a property left out takes its default. In an exported file, a property is left out only where it does not apply (a pull subscription has no `distribution_agent`, a schema-only article no table properties) or where a finding names its path. The kinds of finding tell what a later plan does with them: `out_of_scope` makes it refuse the database, `incomplete` is a state it repairs, `unreadable` marks a value it must not compare, and `note` needs nothing.

### Runtime facts

`-facts PATH` writes, beside the YAML, what the export observed of the replication at run time, as indented JSON. The file is not configuration: it is never compared, never part of the YAML, and it changes with every run. It is the input the planner needs to decide whether a change invalidates the snapshot or reinitializes a subscription:

- `read_at`: the distributor's `SYSDATETIME()` when the facts were read.
- `publications`: per publication, `immediate_sync_ready`, `last_generation` and per article `active` (bit `0x1` of the article status in `sysarticles` or `sysschemaarticles`, set by the snapshot generation). `last_generation` is the end of the latest snapshot agent run that generated a snapshot; empty means no such run is in the retained snapshot history (the history cleanup keeps only recent rows, `history_retention_hours`), not that no snapshot was ever generated. A run that finds no subscription to initialize also ends successfully, and nothing but its final message tells it apart ("A snapshot was not generated because no subscriptions needed initialization."): the export leaves out the runs whose final message contains `not generated`, which assumes the agent writes its messages in English.
- `subscriptions`: per subscription, one row per subscribed article with its status at the publisher (`syssubscriptions`) and at the distributor (`MSsubscriptions`, the subscription's own row; `null` when there is none).
- `agents`: per log reader, snapshot, distribution and pull agent, its id at the distributor, whether its job exists, is enabled and is running (`job` is `null` for a pull agent whose subscriber is not given with `-server`), and its last history row and last failure.
- `profile_uses`: the agents of every distribution database of the distributor that use a user-defined profile, with their `publisher`. The distribution agents of the virtual subscribers are listed too, with `virtual: true` and no `subscriber`: a profile bound to one still matters before it is dropped.

Every time is written as `2006-01-02 15:04:05.000`, in the distributor's local time.

The facts are read only with `-facts`: a plain export runs none of their queries. Reading them needs, besides the permissions above, read access to `msdb.dbo.sysjobactivity` and `syssessions` and to every distribution database of the distributor.

### Empty configuration

Before reading anything, the export probes the publisher through its `master` database. A database with no distributor configured, or not enabled for transactional or snapshot publishing, exports as the empty configuration: the publisher section, no publication, and a `note` finding that says why. When a distributor is configured, the file also holds what already exists there, so that a later plan does not create it again: the `distributor` section and the user-defined agent profiles (`agent_profiles`, every one a normal export lists) and, with `-facts`, the profile uses. A database that is published for merge replication adds an `out_of_scope` finding, whether or not it also has transactional or snapshot publications. A database that is offline, restoring or in standby is an error, not an empty configuration.

## sqlrepl plan

Compares a desired file with what the servers hold and prints the procedure calls that would make them match, each with its costs (snapshot invalidation, reinitialization, data replaced at the subscriber). It changes nothing: like the export, it runs `SELECT` statements only. The file has the format of the export, and an exported file, unchanged, plans no change.

```
sqlrepl plan -f sales.yaml -user sqlrepl -server SUBSRV=subsrv.example.com,1433
sqlrepl plan -f sales.yaml -sql
sqlrepl plan -f sales.yaml -json > plan.json
```

Options:

| Option | Meaning |
|---|---|
| `-f PATH` | the desired file, required |
| `-server NAME=ADDRESS` | address of a server of the file by its name, in any case, repeatable; a server without one is reached at its name. An entry that names no server of the file, no current pull subscriber and not the distributor is opened as a subscriber all the same, and prints `note: -server NAME names no server of the file` on standard error |
| `-user` | SQL Server login, password in `SQLREPL_PASSWORD`; Windows authentication by default |
| `-param key=value` | extra go-mssqldb connection parameter, repeatable |
| `-env PATH` | the `.env` file to read before connecting, `./.env` by default (below) |
| `-sql` | append the T-SQL of the plan to the summary |
| `-json` | print the plan as JSON only, without the summary |
| `-defer-full-snapshot` | when added articles would make the next snapshot a full generation, defer it: the plan turns `immediate_sync` off, generates and waits for the deliveries, then restores it |
| `-wait DURATION` | how long the generate and wait step of `-defer-full-snapshot` waits, `30m` by default |
| `-timeout DURATION` | timeout of each connection (also passed to the driver as `connection timeout`, in whole seconds, unless `-param` sets one) and of the read that follows them, `2m` by default |

The plan reads the publisher (the publication database and `master`), the distributor named in the file, or the one registered at the publisher when the file names none, and the subscribers: those the file names, those of the current pull subscriptions (a pull subscription removed from the file is read and dropped at its subscriber) and every `-server` entry, each once whatever its case. The publisher and the distributor must be reached, or the command fails. A subscriber that cannot be reached does not stop the plan: its preconditions are `unchecked`, a push operation toward it stays planned with that precondition listed, and an operation that runs there (a pull subscription) is refused. This holds for a subscriber the file no longer names too: the drop of a pull subscription removed from the file is refused when its subscriber cannot be reached, and its server name is checked like the file's.

Output. The summary starts with `Plan for SERVER.DATABASE:` and either `no changes.` or the count of operations and of costly ones, then one line per operation (sequence, action, kind, path, costs) with its warnings, the totals per cost, and the sections that are not empty: the secrets the calls pass and whether each is set, the preconditions (`ok`, `failed`, `unchecked`; a subscriber database is written `SERVER/DATABASE`), the agents apply will start, the warnings and the notes. `-sql` appends the calls as T-SQL, one batch per operation, preceded by the server and the database it runs in; a secret appears as a variable with a comment that names it, never as a value. `-json` prints the plan as data: the operations with their calls, costs and affected objects, and every list of the summary.

Costs. Each operation lists one or more of these costs, by name; an operation is costly when it has a cost other than `online` and `shared_object_changed`, and the summary's count of costly operations is the one `apply` will repeat in its confirmation:

| Cost | Meaning |
|---|---|
| `online` | nothing is invalidated, reinitialized or replaced |
| `pending_snapshot_start` | the subscriptions of the article already await a snapshot: the change waits for that snapshot to start |
| `new_snapshot` | the snapshot agent must generate a snapshot that the subscriptions then receive (an added article, a new subscription, an extension) |
| `full_generation_deferred` | the ready snapshot is invalidated and nothing is marked: the next run of the snapshot agent regenerates every article |
| `ready_snapshot_dropped` | the ready snapshot is dropped (`immediate_sync` false), and a subscription added later waits for a generation of its own |
| `reinitialization` | the named subscriptions are reinitialized |
| `drop_and_readd` | the named subscriptions are dropped and added back |
| `subscriber_data_replaced` | the snapshot replaces the data of a subscriber table |
| `subscriber_object_left` | a drop leaves the table or object at the subscriber |
| `shared_object_changed` | a distributor object that other publisher databases use changes; the operation lists those databases |

The costs are taken from the measured cost table (`internal/cost`, each entry citing its rows in `lab/results/2022/`), never from the documentation. The flags follow from the predicted state: `@force_invalidate_snapshot = 1` exactly when the snapshot is predicted ready and the change touches it, `@force_reinit_subscription = 1` exactly when it needs a reinitialization and a subscription row of the operated article is at status 2.

Job operations. Around the calls, the plan lists the job operations `apply` will run: `job_disable` of the snapshot agent of each publication it operates on (first), `job_restore` of the value found (last), and `job_start` of each agent it lists under "Agents apply will start". `-defer-full-snapshot` adds a `generate_and_wait` operation, a snapshot run whose deliveries `apply` waits for.

Agent profiles. An omitted `agent_profiles` key means the file does not manage the profiles: the plan creates, changes and drops none. An explicit `agent_profiles: []` manages them and drops every user profile that no agent uses. An export whose distributor was read writes the key even when it holds no user profile (`agent_profiles: []`), so the exported file manages the profiles; an export that could not read the distributor leaves it out.

Refusals. A plan that would act on something it cannot do safely is refused: it prints the refusals, each with the path concerned and its reason, then `Plan refused.`, and has no operation at all. The command then exits 1; it exits 4 for a plan with a `failed` precondition and no refusal, and 0 otherwise, an empty plan included (exit codes under `sqlrepl apply`). A plan is refused, among others, when:

- the export reports an `out_of_scope` finding (merge publications, peer-to-peer, updatable subscriptions), or an `incomplete` state whose repair is not measured;
- a change has no measured cost (`cost of ... change not measured`): the plan never guesses whether a change invalidates the snapshot or reinitializes a subscription;
- a server answers with another name than the file's (`server X answers as Y: check -server`), or runs a version or edition the change needs;
- a published table does not exist or has no primary key, a subscriber database does not exist, a profile exists neither in the file nor at the distributor, a job the plan updates does not exist: the plan does not create tables, databases or jobs;
- an operation runs at a subscriber that cannot be reached;
- `-defer-full-snapshot` is given with `-wait 0`, refused before any connection.

Secrets and `.env`. The passwords the calls need are never in the file: each is a `password_secret` name, the environment variable that provides it at apply time. The plan does not read their values; it lists each secret and whether its variable is set, so that a missing one shows before apply. Before connecting, the plan loads the `.env` file of `-env` (`KEY=VALUE` lines, `#` comments, an optional `export` prefix, quotes removed): a key is set only when the environment does not already hold it, so a real environment variable always wins, and a missing file is no error. `SQLREPL_PASSWORD` is read after that load, so it can come from the file. Keep `.env` out of version control (the repository's `.gitignore` lists it; `.env.example` shows the keys).

Required permissions: those of the export with its runtime facts (the plan always reads them), and at each subscriber of the file read access to `master` and to the subscriber databases.

## sqlrepl apply

Runs the plan of a desired file against the servers it names, after a confirmation, under an application lock. The plan it runs is the one `sqlrepl plan` prints for the same file and servers, computed again at the start of the run.

```
sqlrepl apply -f sales.yaml -user sqlrepl -server SUBSRV=subsrv.example.com,1433
sqlrepl apply -f sales.yaml -auto-approve -wait 1h
```

Options: those of `plan` without `-sql` and `-json`, plus `-auto-approve`, and two that change meaning:

| Option | Meaning |
|---|---|
| `-auto-approve` | run without asking; required when standard input is not a terminal |
| `-wait DURATION` | the budget of the waits for snapshot generations and deliveries, `30m` by default (below) |
| `-timeout DURATION` | as for `plan`, and also the bound of each read apply makes while running, of each wait for an idle snapshot job, of the retries of a busy agent, and of each restore |

Order of a run:

1. Without `-auto-approve` and without a terminal on standard input, apply exits 2 before connecting: `apply needs a terminal to confirm, or -auto-approve`. `-defer-full-snapshot` with `-wait 0` is refused before connecting too.
2. It connects as `plan` does, then takes the application lock (below) and prints `lock taken on SERVER.DATABASE`.
3. It reads the servers, runs the prechecks and builds the plan, once, and prints the plan's summary.
4. It stops there, with nothing run and exit 1, when the plan is refused, when a precondition is `failed`, when the `msdb job permission` or `sql server agent` precondition is `unchecked` at a server where it runs a job operation, or when a secret of the plan is not set (`secret NAME is not set`, one line per secret; an empty variable is not set). An empty plan prints `Plan for SERVER.DATABASE: no changes.`, asks nothing and exits 0.
5. It asks, exactly: `Apply N operations to SERVER.DATABASE, C costly (COST K, ...)? Type yes to apply: `, the parenthesis listing the costly operations per cost, left out when none is costly. Only the line `yes` applies. Any other answer, end of input, or `Ctrl-C` or `SIGTERM` while the question waits prints `Apply cancelled.`, releases the lock and exits 1.
6. It disables the snapshot jobs of the publications it operates on, runs each statement, starts the agents the plan lists (a distribution or pull agent after the generation its delivery waits for), waits for the deliveries the plan owes, then restores every job it disabled and releases the lock. The restores and the release run on every way out: a failed statement, a spent budget, an interrupt.

The lock. On the publisher, in the publication database, apply takes `sp_getapplock` on the resource `sqlrepl apply`, owned by its session, with no wait: a second apply on the same publication database, or one started while the first waits at its question, exits 1 with `another sqlrepl apply holds the lock on SERVER.DATABASE`, before reading anything. When the file declares `distributor` or `agent_profiles`, the parts shared with other publication databases, apply also takes `sqlrepl apply distributor` in `master` at the distributor, which exists before the distributor is configured, so the lock also covers a plan that creates the distribution database and serializes every distribution database of the instance; without that lock an operation on those parts is refused. A release that fails prints `lock release failed on SERVER.DATABASE: MESSAGE` and makes the exit code 1; a lock whose connection was lost prints `lock lost with the connection`.

The budget. `-wait` starts at the first operation and bounds every wait for a snapshot generation and for the deliveries owed, and the wait of `-defer-full-snapshot`. Spent, apply stops at once, restores the jobs, and lists what remains and every delivery owed with its state. `-wait 0` runs every operation and every agent start, waits for no delivery, and lists every delivery owed as `not awaited`. The waits that belong to running an operation (the wait for an idle snapshot job after disabling it, the retries while an agent is busy) are bounded by `-timeout`; a spent `-timeout` there is a failure of that operation.

Output, on standard output, each line with fixed words:

| Line | When |
|---|---|
| `lock taken on SERVER.DATABASE` | each lock taken |
| the summary of `plan`, then the question | before any operation |
| `refused: precondition NAME OBJECT at SERVER is STATUS: DETAIL` | after the summary, each precondition that stops the run (step 4) |
| `secret NAME is not set` | after the summary, each secret of the plan whose variable is missing or empty |
| `[SEQ/N] ACTION KIND PATH at SERVER, database DATABASE` | before each statement, followed by its text, each line indented two spaces |
| `  ok (MS ms)` | a statement that succeeded |
| `  18752 tolerated, KIND PATH re-read` | a drop or `sync_method` change that returned 18752, done all the same as a re-read shows |
| `  retried after generating (Msg NUMBER)` | a snapshot start retried while a generation ran |
| `  failed: Msg NUMBER: MESSAGE` | a statement that failed |
| `  interrupted` | a statement an interrupt cancelled |
| `waiting for the snapshot job of PUBLICATION to be idle` | a disabled snapshot job still running |
| `waiting for the deliveries of PUBLICATION` | a wait for deliveries that found something to wait for |
| `started KIND PUBLICATION` or `KIND PUBLICATION already running` | each agent start, a distribution agent followed by `SUBSCRIBER/DATABASE` |
| `delivery PUBLICATION to SUBSCRIBER/DATABASE: ...` | each delivery owed, at the end: `confirmed (run FOLDER\RUN)`, `unconfirmed (REASON; job STATE; last history: COMMENTS)` or `not awaited` |
| `job left disabled: JOB` | a snapshot job whose restore failed: enable it by hand |
| `lock lost with the connection` | a lock whose session ended with its connection |
| `lock release failed on SERVER.DATABASE: MESSAGE` | a lock release that failed (exit 1) |
| `Failed at operation SEQ: Msg NUMBER: MESSAGE`, `Remaining: SEQ LIST` | a run that stopped before its last operation |
| `Applied RAN of N operations; deliveries: K confirmed, U unconfirmed, A not awaited.` | last, for a run that got past the question |

Server informational messages are not printed, and the value of every bound secret is replaced by `****` in any message apply prints. An error that ends the run before any operation (a connection, the lock held, the read) goes to standard error with the `sqlrepl:` prefix.

Exit codes, for both commands:

| Code | `plan` | `apply` |
|---|---|---|
| 0 | printed, no refusal, no failed precondition | nothing to do, or every operation ran and every delivery owed is confirmed |
| 1 | an error or a refusal | an error, a refusal, a failed or unchecked precondition it needs, a secret not set, the lock held, `Apply cancelled.`, a failed statement, a lock release that failed, or operations left unrun (an interrupt, a spent bound before the last operation), except the case of code 3 |
| 2 | a usage error | a usage error, or no terminal without `-auto-approve` |
| 3 | not used | every operation ran and a delivery owed is unconfirmed or not awaited; or the wait of `-defer-full-snapshot` timed out or its run failed, operations left unrun (`immediate_sync` stays off), the one exception to code 1 |
| 4 | printed with a failed precondition and no refusal | not used |

An interrupt after the last operation, during the wait for deliveries, ends with the code the deliveries decide (0 or 3). A second interrupt, during the restores, is ignored.

Deliveries owed. A delivery is confirmed by a "Delivered snapshot" line of the subscription's distribution agent, written in the distributor's history after the moment apply recorded it, that names a run of the publication's snapshot folder absent from that folder at that moment (any run, for a subscription added while the snapshot was ready). Apply lists the folder `<root>/unc/<PUBLISHER>_<DATABASE>_<PUBLICATION>` with `sys.dm_os_enumerate_filesystem` at the distributor, matching the name without regard to case. The root is the publication's alternate folder or the publisher's `working_directory`; when the file omits it, apply reads the publisher's `working_directory` from `msdb.dbo.MSdistpublishers` at the distributor. A publication whose folder no listing shows, while every listing shows its root's `unc` folder, has no run yet. A pull subscription is confirmed in the same way, from the distributor's history.

Snapshot reports. Apply writes no snapshot report yet: it prints the outcome of each delivery instead. The report, with `sqlrepl snapshot`, comes later.

Known limits:

- The check of a subscription created with `initialization: lsn` reads `msdb.dbo.restorehistory`, which keys on the destination name: a backup restored under a temporary name and then renamed into place is checked against an older restore of the target name, whose LSN it accepts.
- The snapshot folder of a publisher on a named instance (a name with `\`) is not measured: its deliveries are reported `unconfirmed`, and apply exits 3.
- A publication whose `unc` folder the distributor cannot read is taken as having no run yet: nothing is confirmed by mistake, but its delivery waits the whole `-wait` before it is reported `unconfirmed`.
- A misspelled `profile` in a file that also creates the distributor is found only when the call that uses it fails, mid-plan: before the distributor exists there are no profiles to check against.
- The snapshot folder precondition is not listed when the file omits `working_directory` at the creation of the distributor; `sp_adddistpublisher` refuses a missing folder itself (21037).
- `/dev/null` on standard input counts as a terminal: without `-auto-approve` the question reads end of input and apply exits 1 with `Apply cancelled.`, not 2.
- Setting up a remote distributor is out of scope for now (R17): apply connects to an existing remote distributor and locks it like a local one, but the plan refuses to create its configuration.

Required permissions: those of `plan`, those of every call the plan runs, and, at each server where it runs a job operation, the permission to find, update and start the agent jobs in `msdb`, which the `msdb job permission` precondition checks: `sysadmin`, or `SQLAgentOperatorRole` with `SELECT` on `msdb.dbo.sysjobs`, `sysjobactivity` and `syssessions` (the role alone gets 229 on those tables; the granted case is not measured). The `sql server agent` precondition reads `sys.dm_server_services`, which a login that is not `sysadmin` may be refused without `VIEW SERVER STATE` (not measured); a refused read leaves the precondition `unchecked`, and apply refuses.

## Tests

```
go test ./...
```

`TestQueriesParse` checks the syntax of every query against a real instance, with `SET PARSEONLY`, which does not need replication to be configured. It runs when `SQLREPL_TEST_DSN` is set:

```
SQLREPL_TEST_DSN='server=lpc:localhost\SQLEXPRESS;encrypt=disable' go test ./...
```

`lab/` builds a test replication in a SQL Server Developer container and holds the measurements made on it (`lab/README.md`).
