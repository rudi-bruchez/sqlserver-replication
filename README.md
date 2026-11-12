# sqlserver-replication
Improving and managing SQL Server replication

## Contents

- `stored-procedures/`: source of the SQL Server 2019 replication system procedures, for reference.
- `docs/analysis/step-1-analysis.md`: where the replication configuration lives, how to decode it, and which changes invalidate the snapshot or reinitialize subscriptions.
- `cmd/sqlrepl`: a tool that manages transactional replication as a declarative file. Only the export is implemented.

## sqlrepl export

Reads a publication database, its publications, articles, push and pull subscriptions and agents, and writes them as YAML. It only runs `SELECT` statements, on the publisher, on the distributor and on the subscribers given with `-server`.

Scope: transactional and snapshot replication, push and pull subscriptions, SQL Server publisher. Anything else found (anonymous and updatable subscriptions, peer-to-peer, non-SQL Server subscribers) is reported under `findings`. Each finding has a `kind` (`out_of_scope`, `incomplete`, `unreadable` or `note`), the `path` of the element concerned and a `message`.

Besides the publications, the file holds the distributor properties (cleanup batch sizes, the folders and names of the distribution database files, the security of the `repl_distributor` link, `multi_subnet_failover`), the publisher's `sync_with_backup`, and per publication the partition switch options, `enabled_for_het_sub`, `snapshot.enabled_for_internet` and the `type` and `subscriber_type` of each subscription. A property the export could not read is left out and has a finding.

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

Required permissions: read access to the publication database, and to `msdb` and the distribution database on the distributor; for a pull subscription, to the subscription database and `msdb` on the subscriber.

Passwords are never exported. Where an agent uses SQL Server authentication, the file carries a `password_secret` name instead. Agent command lines are exported with their password arguments masked.

### Runtime facts

`-facts PATH` writes, beside the YAML, what the export observed of the replication at run time, as indented JSON. The file is not configuration: it is never compared, never part of the YAML, and it changes with every run. It is the input the planner needs to decide whether a change invalidates the snapshot or reinitializes a subscription:

- `read_at`: the distributor's `SYSDATETIME()` when the facts were read.
- `publications`: per publication, `immediate_sync_ready`, `last_generation` (the latest successful run of its snapshot agent) and per article `active` (bit `0x1` of `sysarticles.status`, set by the snapshot generation; schema-only articles are listed inactive).
- `subscriptions`: per subscription, one row per subscribed article with its status at the publisher (`syssubscriptions`) and at the distributor (`MSsubscriptions`, the subscription's own row; `null` when there is none).
- `agents`: per log reader, snapshot, distribution and pull agent, its id at the distributor, whether its job exists, is enabled and is running (`job` is `null` for a pull agent whose subscriber is not given with `-server`), and its last history row and last failure.
- `profile_uses`: the agents of every distribution database of the distributor that use a user-defined profile.

Reading the facts needs, besides the permissions above, read access to `msdb.dbo.sysjobactivity` and `syssessions` and to every distribution database of the distributor.

### Empty configuration

Before reading anything, the export probes the publisher through its `master` database. A database with no distributor configured, or not enabled for transactional or snapshot publishing, exports as the empty configuration: the publisher section, no publication, and a `note` finding that says why. A database that is published for merge replication adds an `out_of_scope` finding. A database that is offline, restoring or in standby is an error, not an empty configuration.

## Tests

```
go test ./...
```

`TestQueriesParse` checks the syntax of every query against a real instance, with `SET PARSEONLY`, which does not need replication to be configured. It runs when `SQLREPL_TEST_DSN` is set:

```
SQLREPL_TEST_DSN='server=lpc:localhost\SQLEXPRESS;encrypt=disable' go test ./...
```

`lab/` builds a test replication in a SQL Server Developer container and holds the measurements made on it (`lab/README.md`).
