# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Go tool, `sqlrepl`, that manages SQL Server transactional replication as a declarative file, on the Terraform model: export the current state, diff it against the desired state, generate the `sp_add*` / `sp_change*` / `sp_drop*` calls. The tool replaces the configuration layer only; Microsoft's replication engine (log reader, distribution) stays.

Roadmap and status: step 1 (analysis, `docs/analysis/step-1-analysis.md`) and step 2 (read-only export) are done. The design of steps 3 and 4 is in `docs/superpowers/specs/2026-11-10-sqlrepl-plan-apply-design.md`; plan 1 (`docs/superpowers/plans/`, rename and measurement campaign) is done: the 2022 CU27 results in `lab/results/2022/` are those of commit `21c33a1`, its last measuring commit. Step 3 (plan) and step 4 (apply) are not started; the measurements that gate step 3 are made. The export has run against the lab replication of `lab/README.md` (SQL Server 2022 Developer in podman), which found and fixed the command parsing and the filter procedure and sync view rules.

Scope: transactional replication, push subscriptions, SQL Server publisher. Merge, peer-to-peer, updatable, pull and anonymous subscriptions and Oracle publishers are out of scope; the export reports them under `findings` instead of modelling them.

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

Running the export:

```
sqlrepl export -publisher PUBSRV -database Sales [-distributor DISTSRV] [-o out.yaml]
```

## Architecture

- `internal/decode`: pure functions between the coded values of the system tables (`schema_option` as big-endian `binary(8)`, article `type` and `status` bits, `pre_creation_cmd`, `ins_cmd`/`upd_cmd`/`del_cmd`, schedule codes…) and readable names. Invariant: unknown values are never dropped. They render as `unknown(n)` or as a hex bit, and the `*Code` / `Encode*` inverses accept them, so an export round-trips. Keep that invariant when adding a code table; step 3 relies on the inverses.
- `internal/model`: the YAML file format (`Config`). It holds configuration only, with no runtime state and no secrets: a password appears as a `password_secret` name.
- `internal/reader`: builds a `model.Config` from two connections, the publisher (connected to the publication database) and the distributor. `exporter.run()` reads in a fixed order (distributor, profiles, publications, articles, subscriptions, agents), and later steps depend on earlier ones (`pubIndex`, `articleNames`, `publisherID`). All SQL is in `queries.go`. `{dist}` and `{servers}` are substituted by `distQuery`: the quoted distribution database name, and `MSreplservers` or the `fallbackServers` derived table for distributors older than 2016 SP2 CU3.
- `cmd/sqlrepl`: flag parsing and DSN building (`host\instance,port`, optional `lpc:`/`np:`/`tcp:` prefix mapped to the go-mssqldb `protocol` parameter; Windows authentication when no `-user`).

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

## stored-procedures/

Source of the SQL Server 2019 replication system procedures, as a reference, not part of the build. The public procedures (`sp_changearticle`, `sp_addarticle`, `sp_help*`…) are thin wrappers around `sys.sp_MSrepl_*`, whose code is not in the folder. The rules for snapshot invalidation and reinitialization therefore cannot be read here. The distributor-side procedures (`sp_MShelpsnapshot_agent`, `sp_MShelp_subscription`, `sp_MSenumdistributionagentproperties`, `sp_MShelp_profile`) are real queries and show the correct joins.

## Before step 3

The impact matrix (which property change needs `@force_invalidate_snapshot` or `@force_reinit_subscription`) is measured on the lab (`lab/campaign/02-matrix.sql`, section 5 of the analysis document), and the campaign of `lab/campaign/` measures the rest the planner needs (results in `lab/results/2022/`, one section per script in `lab/README.md`). Microsoft Learn was wrong on several entries (commands and `status` change online; `sp_articlecolumn` works on a subscribed article; the list is in section 5 of the analysis document). The snapshot flag is asked exactly when `immediate_sync_ready = 1`, and the reinit flag when the operated article's subscription is at status 2, or for `sync_method` any article (`05-snapshot-flag`, `S6.O6`). `sync_method` needs a reinitialization only for a change from or to `concurrent` or `concurrent_c`, which marks every subscription; between `native`, `character` and `database snapshot` it marks nothing (`15-snapshot-scope`, rows `C.*.sync_method` and `D.*.sync_method_probe`). Take the plan logic from the measured tables and the rows the design cites, not from Learn. The structural operations (adding an article with and without `immediate_sync`) and the traps of apply (a refused call leaves its transaction open) are measured too, `lab/README.md` rows 9 to 12.

Oracles for verification: `Export-DbaReplServerSetting` (dbatools, wraps RMO `ReplicationServer.Script()`) for the export, and RMO with `SqlExecutionModes.CaptureSql` for generated T-SQL.
