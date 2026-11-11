# sqlserver-replication
Improving and managing SQL Server replication

## Contents

- `stored-procedures/`: source of the SQL Server 2019 replication system procedures, for reference.
- `docs/analysis/step-1-analysis.md`: where the replication configuration lives, how to decode it, and which changes invalidate the snapshot or reinitialize subscriptions.
- `cmd/sqlrepl`: a tool that manages transactional replication as a declarative file. Only the export is implemented.

## sqlrepl export

Reads a publication database, its publications, articles, push subscriptions and agents, and writes them as YAML. It only runs `SELECT` statements, on the publisher and on the distributor.

Scope: transactional and snapshot replication, push subscriptions, SQL Server publisher. Anything else found (pull subscriptions, updatable subscriptions, peer-to-peer, non-SQL Server subscribers) is reported under `findings`. Each finding has a `kind` (`out_of_scope`, `incomplete`, `unreadable` or `note`), the `path` of the element concerned and a `message`.

Besides the publications, the file holds the distributor properties (cleanup batch sizes, the folders and names of the distribution database files, the security of the `repl_distributor` link, `multi_subnet_failover`), the publisher's `sync_with_backup`, and per publication the partition switch options, `enabled_for_het_sub`, `snapshot.enabled_for_internet` and the `type` and `subscriber_type` of each subscription. A property the export could not read is left out and has a finding.

```
go build ./cmd/sqlrepl
sqlrepl export -publisher PUBSRV -database Sales -o sales.yaml
```

Options:

| Option | Meaning |
|---|---|
| `-publisher` | publisher instance: `host`, `host\instance`, `host,port`, optionally prefixed by a protocol (`lpc:`, `np:`, `tcp:`) |
| `-database` | publication database |
| `-distributor` | distributor instance; by default, the distributor registered at the publisher |
| `-publisher-name` | publisher name registered at the distributor, when it differs from `@@SERVERNAME` (publication database in an availability group) |
| `-user` | SQL Server login, password in `SQLREPL_PASSWORD`; Windows authentication by default |
| `-param key=value` | extra go-mssqldb connection parameter, repeatable (`-param encrypt=disable`) |
| `-o` | output file; standard output by default |

Required permissions: read access to the publication database, and to `msdb` and the distribution database on the distributor.

Passwords are never exported. Where an agent uses SQL Server authentication, the file carries a `password_secret` name instead. Agent command lines are exported with their password arguments masked.

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
