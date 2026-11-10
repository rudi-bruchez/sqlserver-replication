# sqlrepl plan and apply

Design of the declarative engine of `sqlrepl`: describe a SQL Server replication in a file, see what it takes to get there, and get there. Written on 2026-11-10 from a conversation with Rudi; the parts marked "my call" are decisions taken while writing, to be checked.

Reference material this design relies on, and does not repeat:

- `docs/analysis/step-1-analysis.md`: where the configuration lives, how it is coded, the measured impact matrix (section 5), the order of operations (section 6);
- `lab/README.md`: the lab container and the measurements made on it (rows 1 to 12);
- `CLAUDE.md`: the traps already paid for in the reader.

## Intent

Setting up SQL Server transactional replication means chaining a dozen system procedures (`sp_adddistributor`, `sp_adddistributiondb`, `sp_adddistpublisher`, `sp_replicationdboption`, `sp_addlogreader_agent`, `sp_addpublication`, `sp_addpublication_snapshot`, `sp_addarticle`, `sp_articlefilter`, `sp_articleview`, `sp_addsubscription`, `sp_addpushsubscription_agent`…) in the right order, with parameters whose interactions are documented badly or not at all. Changing an existing replication is worse: each change may silently need a new snapshot or a reinitialization of the subscriptions, and Microsoft Learn is wrong on several of them (measured, analysis section 5).

`sqlrepl` lets a DBA describe the replication they want in one YAML file, and does the procedures for them. The first situation it serves is creating a replication from nothing. The second is changing an existing one, adding or removing articles, changing filters or properties, each time by the least costly path the measurements allow.

The tool is a single Go binary, `sqlrepl`. It replaces the configuration layer only: Microsoft's replication engine (log reader, snapshot and distribution agents) keeps doing the replicating.

## Where this sits in sqlrepl

`sqlrepl` is meant to analyze, plan, apply and monitor. This design covers the engine: `export` (exists), `plan` and `apply`. Each of the following gets its own design later, in this order:

1. a local web GUI, served by `sqlrepl` on localhost: creation wizard, editing of an existing configuration with the cost of each change shown while editing, review and apply of a plan, monitoring view;
2. monitoring: agent status, latency (tracer tokens), undistributed commands, agent errors;
3. data validation between publisher and subscriber;
4. configuration audit (risky settings);
5. performance analysis.

The engine must be built so that the GUI is a front end on it, not a second implementation (see "Engine as a library").

## Goals

- Create a complete replication from one file: distributor (local or remote), publication database, publications, articles, filters, subscriptions and their agents.
- Change an existing replication by editing the file: add, change or drop any object the file describes.
- Show, before anything runs, the exact operations, the exact T-SQL, and the cost of each operation.
- Converge: after a successful `apply`, `plan` on the same file finds nothing to do.

## Scope

In scope:

- transactional publications and snapshot publications;
- push and pull subscriptions;
- the distributor: creation if missing, local or remote, its retention and its snapshot working directory;
- agents: log reader, snapshot, distribution (independent and shared), their schedules, profiles and security;
- user-defined agent profiles;
- SQL Server 2019, 2022 and 2025, as publisher, distributor and subscriber. Other versions are refused with a clear message.

Out of scope: merge replication, peer-to-peer, updatable subscriptions (immediate or queued), anonymous subscriptions, non-SQL Server publishers or subscribers. The export reports them under `warnings`; `plan` refuses a database that has any, rather than dropping what it cannot model.

## Non-goals

- Uninstalling the distributor. The file never causes `sp_dropdistributor` or `sp_dropdistributiondb`; a distributor that is no longer needed is removed by hand. My call: the distributor serves other publication databases the file does not see.
- Creating or changing the schema of published tables, or the subscriber databases themselves. They must exist; `plan` checks it and says so.
- Creating the snapshot folder on disk. `plan` cannot see the file system of a remote server; it checks what it can (`xp_fileexist` or equivalent at the distributor) and warns.
- Rolling back a partly applied plan (see "Apply").

## Anti-goals

These four make `sqlrepl` a failure even if it works. Each is a hard rule for the builder, with the mechanism that enforces it.

1. A hidden reinitialization or snapshot. Every operation that invalidates a snapshot, reinitializes subscriptions, or drops and re-adds subscriptions is marked in the plan, with the publications, articles and subscriptions it affects. `apply` repeats the count of such operations in its confirmation question.
2. Opaque T-SQL. `plan` can print the exact T-SQL that `apply` will run, statement by statement and server by server, and `apply` logs each statement before running it. There is no other code path that changes the servers.
3. Silent divergence between publisher and subscriber. The engine never generates a configuration known to diverge without error. Known case: a row filter given only as `sp_addarticle @filter_clause`, which filters the snapshot and not the changes (lab row 12); a filter is always created with `sp_articlefilter`, and the synchronization view with `sp_articleview`.
4. Unannounced loss of subscriber data. Operations that delete or replace data at the subscriber are marked as such: a reinitialization of an article whose `pre_creation_cmd` is `drop`, `delete` or `truncate`, and a change of `pre_creation_cmd` itself. Dropping an article or a subscription leaves the subscriber table in place, and the plan says so.

## The file

### Unit and format

One file describes one publication database: its distributor, its publications, their articles and subscriptions, and its agents. Several databases are several files. The format is the YAML of the existing export (`internal/model`), extended for pull subscriptions and snapshot publications. `sqlrepl export` gives the starting file of an existing replication; for a new one, the user writes it (later, the GUI wizard writes it).

### The whole truth

The file is the whole truth for its publication database. A publication, article, subscription, agent schedule or user profile that exists on the server and is not in the file is dropped by the plan. The plan marks drops like any other cost.

### Omitted properties

A property left out of a declared object means the SQL Server default, the value the `sp_add*` procedure uses when the parameter is not passed. If the server holds another value, the plan changes it back. This keeps a hand-written file short while keeping "whole truth" true down to properties.

Consequences for the builder:

- the model must tell "left out" from "false" or zero; a normalization step fills the defaults into the desired configuration before the comparison;
- the defaults are a table in the code, one entry per property, each with its source: Learn, or a lab measurement where Learn is wrong (for example the default `schema_option` of a table article is `0x30073`, not Learn's `0x30F3`, lab row 2);
- the export keeps writing every property, so that an exported file is explicit.

### What is not compared

- Names that replication generates: job names, generated synchronization views (`syncobj_0x…`), generated command procedures when the file does not name them.
- Values derived from other properties: article status bits `0x8` and `0x20` when `schema_option` has `0x8` (lab row 3).
- Runtime state: subscription status, `immediate_sync_ready`, history.
- The agent command line (`command`). My call: the export shows it for information, the plan ignores it, and warns when it carries parameters beyond those the procedures generate; agent tuning belongs in profiles.

### Names

Server names are compared case-insensitively (`syssubscriptions.srvname` is stored in upper case). Stored commands are compared as stored: a procedure given without a schema is stored without one (analysis section 5).

### Secrets and connections

The file holds no secret. A password appears as a `password_secret` name. At `plan` and `apply` time, `sqlrepl` reads the value from the environment variable of that name, after loading an optional `.env` file (default `./.env`, `-env` flag), where the real environment wins. The loader is the stdlib-only `internal/dotenv` of `~/Sources/Repos/atelier/outils/sylloge/internal/dotenv/`, copied, not imported. `plan` reports every secret the plan needs and whether it is set; `apply` refuses to start while one is missing.

Servers are named in the file by their SQL Server name (`@@SERVERNAME`), which is what replication stores and may not resolve from where `sqlrepl` runs (the lab's `REPLLAB`). How `sqlrepl` reaches each server, and with which credentials, is given at run time, never in the file: the builder chooses between flags (`-server REPLLAB=tcp:127.0.0.1,11980`) and a connections file kept outside the repository. `sqlrepl` connects to the publisher, the distributor, and each subscriber that has a pull subscription or whose database must be checked.

## plan

`sqlrepl plan -f desired.yaml` reads the current state (the export's reader), normalizes the desired file, compares them, and prints the plan. It runs only `SELECT` statements and read-only checks.

### What a plan is

A plan is an ordered list of operations. Each operation has:

- the object it acts on (distributor, publication, article, subscription, agent, profile) and the kind of change (add, change, drop);
- the property changes it carries, before and after;
- the server and database it runs on;
- the exact T-SQL;
- its cost, one or more of: online, new snapshot, reinitialization of named subscriptions, drop and re-add of named subscriptions, subscriber data replaced, subscriber object left behind;
- the reason for that cost, with its source (matrix row, lab row, Learn page);
- warnings.

The plan as a whole also lists the secrets it needs, the preconditions it checked (subscriber database exists, published table exists and has a primary key for a transactional article, snapshot folder visible), and the agents `apply` will start.

Output: a human summary (one line per operation with its cost, then the totals), `-sql` for the full T-SQL, and `-json` for the plan as data, which the GUI and the tests consume. My call: a plan is never saved to be applied later; `apply` always recomputes it (see "Apply").

### Costs

The cost of each change comes from the measured matrix (analysis section 5), kept in the code as a table with the source of each entry. Where the matrix is measured on 2022 only, the builder reruns the lab measurements on 2019 and 2025 (`lab/measure-*.sql`, `lab/measure-*.sh`) before relying on them, and records the results per version. The cost of a change depends on the publication: on an `immediate_sync` publication a snapshot-affecting change needs `@force_invalidate_snapshot = 1`, on another it does not (measured).

The plan passes exactly the flags the matrix says are needed, never both by default.

### Strategies

The engine chooses how to reach the desired state. The rules below are the ones known now; each comes from a measurement or a Learn statement cited in the analysis.

- Add an article to an `immediate_sync` publication: `sp_addarticle` with `@force_invalidate_snapshot = 1`; existing subscriptions get it at once; the next snapshot is regenerated for the whole publication but only the new article is delivered (lab row 9). Cost: new snapshot, no reinitialization.
- Add an article to another publication: `sp_addarticle` with no flag, then `sp_addsubscription @article` for each existing subscription (lab row 10). Cost: snapshot of the new article.
- Row filter: `sp_articlefilter` with a filter name, then `sp_articleview`, never `@filter_clause` alone (anti-goal 3).
- Drop an article: drop the subscriptions to that article (`sp_dropsubscription @article`), then the article. On an `immediate_sync` publication, a subscription to one article that is dropped cannot be added back unless all are (analysis section 5, structural operations): a plan that drops an article and adds it back there is turned into a full reinitialization of the affected subscriptions, announced.
- Property chains: `allow_anonymous` needs `immediate_sync` needs `independent_agent`; `compress_snapshot` needs `alt_snapshot_folder`; `enabled_for_internet` needs `ftp_address`; `replicate_partition_switch` needs `allow_partition_switch`. Enable from the bottom up, disable from the top down (measured).
- `independent_agent` cannot change while the publication has subscriptions (error 20013): the plan drops the subscriptions, changes the property, and adds them back. Cost: drop and re-add, which reinitializes them.
- Properties that no flag can change while subscriptions exist (`enabled_for_het_sub`, `allow_push = false` with push subscriptions): same treatment, or a refusal with the reason when the file asks for something impossible.
- A change refused for any reason the engine does not model: the plan stops with the error the procedure would give, rather than guessing.

### Order

The order of section 6 of the analysis, extended for creation:

1. distributor: create or change (`sp_adddistributor`, `sp_adddistributiondb`, `sp_adddistpublisher`, `sp_changedistributiondb`, `sp_changedistpublisher`);
2. publication database: `sp_replicationdboption publish`, log reader agent;
3. drop subscriptions to removed articles, and subscriptions removed from the file;
4. drop removed articles, then removed publications;
5. change publication properties, in the order of the chains above;
6. change kept articles;
7. add publications and their snapshot agents, then articles, filters and views;
8. add subscriptions and their agents (push at the distributor; pull at the subscriber and the publisher), or extend existing subscriptions to new articles;
9. user profiles and agent schedules.

The builder may refine it; the plan's tests must prove that the order satisfies every dependency measured.

## apply

`sqlrepl apply -f desired.yaml`:

1. recomputes the plan against the live servers, so it never runs a stale plan;
2. prints it, with the count of costly operations, and asks for `yes` (skipped with `-auto-approve`; refused when there is no terminal and no `-auto-approve`);
3. runs the operations in order, each on its server, logging each statement before it runs;
4. after each failed statement, checks `@@TRANCOUNT` and rolls back what the procedure left open (lab row 11), then stops;
5. on success, starts the snapshot agent of each publication whose snapshot was invalidated or that has a new or reinitialized subscription, and reports it.

On failure, `apply` reports what ran, what failed with the server's message, and what remains. It does not undo. Running `plan` again reads the server as it is and plans from there; the operations already done are no longer in it. This is why convergence ("plan after apply is empty") is a requirement, not a nicety.

My call: `apply` does not wrap the operations in one transaction. Several procedures create jobs, databases or linked servers, some on other servers, and cannot all be undone by one rollback.

## Engine as a library

The GUI will drive the same engine. Constraints on the builder:

- the comparison and the plan are pure functions of two `model.Config` values and the cost table, with no database access, so that the GUI can recompute costs on every edit and the tests can cover them without a server;
- reading the servers (the existing `internal/reader`), computing the plan, and executing it are separate packages;
- the plan is a Go value that serializes to JSON without loss; `-json` and the GUI use the same serialization;
- the CLI only parses flags and prints.

## Renaming

`replcfg` becomes `sqlrepl`: the command (`cmd/sqlrepl`), its usage and messages, the environment variables (`SQLREPL_PASSWORD`, `SQLREPL_TEST_DSN`), and the documentation. The Go module path stays `github.com/rudi-bruchez/sqlserver-replication`, the repository's name. My call; the rename is the first task of the plan.

## Extending the export

The export must read what the plan manages, since the plan compares against it:

- pull subscriptions: today the export warns and skips them; it must read them at the publisher (`syssubscriptions.subscription_type = 1`) and their agents at the subscriber (`MSreplication_subscriptions`, the pull agent job);
- snapshot publications (`repl_freq = 1`): today reported under `warnings`;
- whatever the normalization needs to tell a generated name from a chosen one.

## Testing

- Unit tests for the normalization, the comparison, the cost table and the ordering, with configurations built in Go; no server.
- Integration tests on the lab container, gated by an environment variable like `TestQueriesParse`. The central scenario: start from an instance with no replication, apply a file, export, check that the export normalizes to the file and that `plan` is empty. Then a set of change scenarios, one per strategy above, each checking the plan's operations and costs before applying, and convergence after.
- The lab runs on 2022 today. The integration tests must also run on 2019 and 2025 images before the support claim holds.
- Each strategy and each cost entry has a test that fails when the rule is broken. The builder breaks each rule once to watch its test fail.

## Left to the builder

- Package layout below the constraints of "Engine as a library".
- How the model marks omitted properties (pointers, a separate presence set, or defaults applied at load).
- The connection mapping (flags or a local connections file), within the rule that it stays out of the configuration file.
- The text layout of the human summary.
- The exact list of preconditions `plan` checks, beyond those named here.
