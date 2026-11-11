# sqlrepl plan and apply

Design of the declarative engine of `sqlrepl`: describe a SQL Server replication in a file, see what it takes to get there, and get there. Written on 2026-11-10 from a conversation with Rudi, then revised the same day after a builder check and two rounds of external review (Mistral Large and GLM through Vibe, codex, Claude readers), whose findings were run on the lab. The parts marked "my call" are decisions taken while writing, to be checked.

Reference material this design relies on, and does not repeat:

- `docs/analysis/step-1-analysis.md`: where the configuration lives, how it is coded, the measured impact matrix (section 5), the order of operations (section 6);
- `lab/README.md`: the lab container and the measurements made on it (rows 1 to 12);
- `CLAUDE.md`: the traps already paid for in the reader.

Facts established by the review rounds are cited as "panel", with the error number or the measurement; they are to be folded into `lab/` by the measurement campaign (see "Measurement campaign").

## Intent

Setting up SQL Server transactional replication means chaining a dozen system procedures (`sp_adddistributor`, `sp_adddistributiondb`, `sp_adddistpublisher`, `sp_replicationdboption`, `sp_addlogreader_agent`, `sp_addpublication`, `sp_addpublication_snapshot`, `sp_addarticle`, `sp_articlefilter`, `sp_articleview`, `sp_addsubscription`, `sp_addpushsubscription_agent`…) in the right order, with parameters whose interactions are documented badly or not at all. Changing an existing replication is worse: each change may silently need a new snapshot or a reinitialization of the subscriptions, and Microsoft Learn is wrong on several of them (measured, analysis section 5).

`sqlrepl` lets a DBA describe the replication they want in one YAML file, and does the procedures for them. The first situation it serves is creating a replication from nothing. The second is changing an existing one, adding or removing articles, changing filters or properties, each time by the least costly path the measurements allow.

The tool is a single Go binary, `sqlrepl`. It replaces the configuration layer only: Microsoft's replication engine (log reader, snapshot and distribution agents) keeps doing the replicating.

## Where this sits in sqlrepl

`sqlrepl` is meant to analyze, plan, apply and monitor. This design covers the engine: `export` (exists), `plan`, `apply`, and `snapshot` with its report (see "Snapshot runs and their report"). Each of the following gets its own design later, in this order:

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
- Converge: after a successful `apply`, `plan` on the same file finds nothing to do, and the data at the subscriber is what the file describes.

## Scope

In scope:

- transactional publications and snapshot publications;
- push and pull subscriptions, initialized by snapshot, by "replication support only" (data already in place), from a backup, or from a log sequence number;
- the distributor: creation if missing, local or remote, its retention and its snapshot working directory;
- agents: log reader, snapshot, distribution (independent and shared), their schedules, profiles and security, including Windows job accounts;
- user-defined agent profiles;
- SQL Server 2019, 2022 and 2025, as publisher, distributor and subscriber. Other versions are refused with a clear message. The support claim for a version holds once the measurement campaign has run on it.

Out of scope: merge replication, peer-to-peer, updatable subscriptions (immediate or queued), anonymous subscriptions, non-SQL Server publishers or subscribers. The export reports them under `warnings`; `plan` refuses a database that has any, rather than dropping what it cannot model.

## Non-goals

- Uninstalling the distributor. The file never causes `sp_dropdistributor` or `sp_dropdistributiondb`.
- Moving a publication database to another distributor. A file that names a different distributor from the one in place, or a remote one where it is local, is refused by `plan` with the reason: the move means `sp_dropdistributor` at the publisher, which removes every publication. My call.
- Creating or changing the schema of published tables, or the subscriber databases themselves. They must exist; `plan` checks it and says so.
- Creating the snapshot folder on disk. `plan` checks what it can (`xp_fileexist` or equivalent at the distributor) and warns.
- Rolling back a partly applied plan (see "Apply").

## Anti-goals

These four make `sqlrepl` a failure even if it works. Each is a hard rule for the builder, with the mechanism that enforces it.

1. A hidden reinitialization or snapshot. Every operation that invalidates a snapshot, reinitializes subscriptions, or drops and re-adds subscriptions is marked in the plan, with the publications, articles and subscriptions it affects. `apply` repeats the count of such operations in its confirmation question.
2. Opaque T-SQL. `plan -sql` prints the T-SQL that `apply` will run, statement by statement and server by server, identical except for secret values (see "Secrets"), and `apply` logs each statement before running it. There is no other code path that changes the servers.
3. Silent divergence between publisher and subscriber. The engine never generates a configuration known to diverge without error. Known cases, each with its rule in "Strategies": a row filter given only as `sp_addarticle @filter_clause` (lab row 12); a synchronization view left on an old filter or column list (panel); a subscription re-added with `@article = 'all'` that comes back active without its data (panel); a subscription dropped and re-added without snapshot initialization while changes were being made (panel).
4. Unannounced loss of subscriber data. Operations that delete or replace data at the subscriber are marked as such: a reinitialization of an article whose `pre_creation_cmd` is `drop`, `delete` or `truncate`, and a change of `pre_creation_cmd` itself. Dropping an article or a subscription leaves the subscriber table in place, and the plan says so.

## The file

### Unit and format

One file describes one publication database: its distributor, its publications, their articles and subscriptions, and its agents. Several databases are several files. The format is the YAML of the existing export (`internal/model`), extended (see "Extending the model and the export"). `sqlrepl export` gives the starting file of an existing replication; for a new one, the user writes it (later, the GUI wizard writes it).

### The whole truth

The file is the whole truth for its publication database. A publication, article, subscription or agent schedule of that database that exists on the server and is not in the file is dropped by the plan, and the plan marks drops like any other cost. Objects shared with other databases follow the rules of "Shared distributor objects".

### Omitted properties

A property left out of a declared object means the SQL Server default: the value the `sp_add*` procedure stores when the parameter is not passed. If the server holds another value, the plan changes it back.

Defaults are not one value per property. They depend on the context of the object, measured by the panel:

| Object, context | Default measured (2022 CU27; same on 2019 CU32 and 2025 CU10 where checked) |
|---|---|
| table article, transactional publication, `native` or `concurrent` | `schema_option 0x30073`; commands `CALL [dbo].[sp_MSins_…]`, `SCALL [dbo].[sp_MSupd_…]`, `CALL [dbo].[sp_MSdel_…]` (an unqualified procedure name in a command is stored with `[dbo]`, even for a source table in another schema: the file writes the schema it means, and the reader compares against the stored one); destination owner: the source schema (`sales.S1` gives `sales`); status 16 (parameterized); `pre_creation_cmd` drop |
| table article, transactional publication, `character` | `schema_option 0x30073`; commands `SQL`; destination owner NULL |
| table article, snapshot publication | `schema_option 0x30071`; commands `SQL` |
| schema-only article (view, procedure) | `schema_option 0x1` |
| publication | `sync_method native`, `retention 336`, `independent_agent 0`, `immediate_sync 0`, `allow_push 1`, `allow_pull 0`, `replicate_ddl 1`, `allow_subscription_copy 0`, `allow_initialize_from_backup 0`, `snapshot_in_defaultfolder 1`, `status inactive` |

The table is a sample: the complete defaults, for every parameter of every in-scope procedure, come from the measurement campaign. The builder's defaults table is keyed by object type and by the properties the default depends on (publication type, `sync_method`, article type), each entry with its source. Where a property requires another, an omitted prerequisite takes the value the declared property requires, not the procedure default: `immediate_sync` needs `independent_agent` (`sp_addpublication @immediate_sync = 'true'` alone is refused with 21022 and does not fill it, panel), a pull subscription needs `allow_pull` and a push subscription `allow_push` on its publication (`sp_addsubscription` returns 20012 otherwise, panel). Otherwise a short file would normalize to a combination the server refuses.

Three properties have no default and must be written in the file: `status` of a publication, `initialization` of a subscription, and the name of a row filter's procedure (`sp_articlefilter` refuses a NULL `@filter_name`, 14043; the engine never invents one, and never falls back on `sp_addarticle @filter_clause`). My call. The procedure default for `status` is `inactive`, and a short hand-written file applied to an active publication would deactivate it with a cost the plan would present as online (panel).

The export keeps writing every property, so that an exported file is explicit.

### What is not compared

- Names that replication generates: job names, generated synchronization views (`syncobj_0x…`), generated command procedures when the file does not name them.
- Values derived from other properties: article status bits `0x8` and `0x20` when `schema_option` has `0x8` (lab row 3).
- Runtime state: subscription status, `immediate_sync_ready`, history, and the `active` bit (`0x1`) of an article's status, which the snapshot sets once delivered and no procedure sets (panel).
- Schedule dates and times set at creation (`start_date` is the creation day) when the file does not declare a schedule. A schedule left out of the file means the schedule the procedure creates (for example daily every 5 minutes for a snapshot agent on the lab), compared on its frequency fields only. A declared schedule is compared in full.
- The agent command line (`command`). The export shows it for information, the plan ignores it, and warns when it carries parameters beyond those the procedures generate; agent tuning belongs in profiles. My call.
- The existence of a shared distribution agent: it is created with the first subscription that uses it and disappears with the last (to confirm by the campaign); its properties are compared while it exists. My call.
- The `initialization` of an existing subscription. It is a creation parameter: it decides how the subscription is created, and how it is re-created when a plan must drop and re-add it. Changing it alone plans nothing, with a note.

### Names

Server names are compared case-insensitively (`syssubscriptions.srvname` is stored in upper case). Command procedures are always written by the engine schema-qualified, in `sp_addarticle` and in `sp_changearticle` alike: the two procedures store an unqualified name differently (`sp_addarticle` qualifies it with `dbo`, `sp_changearticle` keeps it unqualified, panel, on 2022 and 2025), so passing the file's text through would never converge. Normalization qualifies an unqualified name in the file with the schema `sp_addarticle` would use (measured `dbo` for a `dbo` table; other schemas are measured by the campaign).

## Shared distributor objects

The distributor serves other publication databases the file does not see. For the objects that belong to the distributor rather than to the database (Rudi's decision):

- the distributor, the distribution database, its retention, the `MSdistributor` properties and user agent profiles can be created and changed by the file;
- they are never dropped while something uses them. A user profile is dropped only when it is absent from the file and no agent of any database at that distributor uses it; which profile is the default of its agent type is a distributor-wide setting;
- a change to a shared object is marked "shared" in the plan, with the list of the other publication databases the distributor serves. Two files that disagree on a shared value therefore each show the change as shared when they are planned; `plan` cannot see the other file, so it reports the conflict by showing that the server's value differs from what this file wants on a shared object. My call on the mechanism.

The reader must read every profile of the distributor and which agents use it, not only those used by this database (today `collectProfiles` reads only the latter, panel).

## plan

`sqlrepl plan -f desired.yaml` reads the current state, normalizes the desired file, compares them, and prints the plan. It runs only `SELECT` statements and read-only checks.

### Inputs

The comparison takes three inputs: the desired configuration, the current configuration (the reader's `model.Config`), and the observed runtime facts the costs depend on: per subscription its status and the articles it actually covers, per publication whether a snapshot has been generated and is still valid (`immediate_sync_ready`), and whether a snapshot is pending: invalidated and not regenerated, or awaited by a subscription not yet initialized. My call: the measured costs depend on these facts (analysis section 5), so they are an explicit input rather than a guess; the GUI supplies them the same way.

The reader keeps apart two kinds of findings that today share one `warnings` list: out-of-scope features (merge, peer-to-peer, updatable or anonymous subscriptions, non-SQL Server peers), for which `plan` refuses the database, and incomplete in-scope objects (a publication without its snapshot agent, a subscription not covering every article of a publication where that cannot exist), which are part of the current state and which the plan repairs. A blanket refusal would block the repair of an interrupted `apply` (panel).

The reader returns an empty current configuration for an instance with no distributor, or a database not enabled for publishing, instead of an error (today `readDistributor` fails when the publisher is not registered, panel). That is the starting point of every creation.

### What a plan is

A plan is an ordered list of operations. Each operation has:

- the object it acts on (distributor, publication, article, subscription, agent, profile) and the kind of change (add, change, drop);
- the property changes it carries, before and after;
- the server and database it runs on, from a table in the code with one measured entry per procedure: `sp_adddistributor` and `sp_adddistributiondb` in `master` (5001 elsewhere, panel), `sp_addsubscription` and the `sp_add*_agent` procedures of push subscriptions in the publication database at the publisher, the pull procedures in the subscription database at the subscriber, and so on;
- the exact T-SQL, with secrets as named parameters;
- its cost, one or more of: online, start of a pending snapshot, new snapshot, reinitialization of named subscriptions, drop and re-add of named subscriptions, subscriber data replaced, subscriber object left behind, shared object changed;
- the reason for that cost, with its source (matrix row, lab row, panel measurement);
- warnings.

The plan as a whole also lists the secrets it needs and whether each is set, the preconditions it checked (subscriber database exists, published table exists and has a primary key for a transactional article, error 14088 otherwise, snapshot folder visible, no subscription declared on a publication declared inactive, error 21000 otherwise), and the agents `apply` will start.

Output: a human summary (one line per operation with its cost, then the totals), `-sql` for the T-SQL, and `-json` for the plan as data, which the GUI and the tests consume. A plan is never saved to be applied later; `apply` always recomputes it. My call.

### Costs and unmeasured changes

The cost of each change, and the flags it needs, come from a cost table in the code, one entry per change and context, each with its source. Only measured entries exist (Rudi's decision): a change that has no measured entry is refused by `plan` with "cost of <change> not measured", never guessed and never sent to the server to find out. The measurement campaign fills the table before the planner is written.

The plan passes exactly the flags the entry says are needed, never both by default.

### Strategies

The rules known now. Each comes from a measurement or a Learn statement cited in the analysis or the panel; the campaign confirms or replaces the entries marked "to confirm".

The publication properties a strategy depends on (`immediate_sync`, `sync_method`, whether a snapshot is generated) are those in effect when the operation runs: the target values for operations ordered after the publication property changes (step 6 of the order), the current ones before. My call.

Articles:

- Add an article to a publication that keeps its snapshot (`immediate_sync`): `sp_addarticle` with `@force_invalidate_snapshot = 1`; existing subscriptions get it at once; the next snapshot is regenerated for the whole publication but only the new article is delivered (lab row 9). Cost: new snapshot.
- Add an article to a publication without `immediate_sync`, `native` or `character` sync: `sp_addarticle` with no flag, then `sp_addsubscription @article` for each existing subscription (lab row 10). Cost: snapshot of the new article.
- Add an article to a publication without `immediate_sync`, `concurrent` or `concurrent_c` sync (the most common transactional configuration): `sp_addsubscription @article = '<name>'` is refused with 14100, "Specify all articles when subscribing to a publication using concurrent snapshot processing" (panel); the extension is `sp_addsubscription @article = 'all'`. Measured: only the new article is delivered, existing articles are not sent again (panel, second round). Cost: snapshot of the new article.
- Add an article to an `immediate_sync` publication without regenerating every table (Rudi's request, 2026-11-11). The rule above regenerates the snapshot of the whole publication: every published table is read again, under the locks its `sync_method` takes, even though only the new article is delivered. `plan -defer-full-snapshot` replaces it with: `sp_changepublication` `allow_anonymous` to false when it is true, then `immediate_sync` to false; `sp_addarticle` and the extension of the existing subscriptions by the rules for a publication without `immediate_sync`; the snapshot agent started for the new article only; then `immediate_sync` and `allow_anonymous` restored. The full generation is not avoided but deferred: with `immediate_sync` back on, the next snapshot (for a new subscriber or a reinitialization) covers every article again, and the plan says so. Which tables each step generates, the flags each step needs, and what a subscriber added after the restore receives are campaign item 12; until measured, `plan` refuses the option with "cost of deferred snapshot not measured". The default stays the rule above. My call: an option of `plan`, not a property of the file, because it is a choice of path, not of end state.
- Drop an article: `sp_dropsubscription @article, @subscriber, @destination_db` for each subscription to it, then `sp_droparticle`. `sp_droparticle` needs `@force_invalidate_snapshot = 1` exactly when the publication has `immediate_sync` and its snapshot has been generated (`immediate_sync_ready = 1`): measured refused with 20607 there, accepted without the flag on an `immediate_sync` publication with no snapshot yet and on a publication without `immediate_sync` whose snapshot was delivered (panel, second round, consistent with analysis section 5). The same condition governs `sp_addarticle` and the `sp_change*` flags; the campaign confirms it per version. Cost: new snapshot where the flag is needed. A subscribed article is refused with 14046: the subscriptions to it are dropped first.
- Drop an article and add it back in the same publication: `sp_droparticle` then `sp_addarticle`, both with the flags above; on an `immediate_sync` publication the existing subscriptions are extended to the re-added article automatically and it is delivered by the next snapshot (panel). The plan never re-adds the subscription alone with `@article = 'all'` after dropping it for one article: the article comes back active with no data delivered (panel).
- Move an article between publications: drop from the source, add to the target, with the rules above (panel: executes).

Filters and views. The synchronization view is what the snapshot reads; the filter procedure is what the log reader uses. The two must always carry the same clause and column list:

- a row filter is created or changed by `sp_articlefilter @filter_name, @filter_clause`, immediately followed by `sp_articleview @view_name, @filter_clause` with the same clause;
- a row filter is dropped by `sp_articlefilter @filter_clause = NULL`, which drops the filter procedure (panel, second round), immediately followed by `sp_articleview @view_name, @filter_clause = NULL`;
- a column filter (`sp_articlecolumn`) is applied before the `sp_articleview` call. The last review round saw `sp_articlecolumn` rebuild an existing view by itself (campaign case `F6` confirms it); the plan still re-issues `sp_articleview` with the article's clause after a column change, which costs nothing and does not depend on that behavior;
- `sp_articleview` is never called without the article's clause: called without `@filter_clause`, it rebuilds the view unfiltered and also sets `sysarticles.filter_clause` to NULL, while the filter procedure keeps filtering the changes (verified after the panel: snapshot unfiltered, changes filtered, export showing no filter);
- `sp_addarticle @filter_clause` is never generated alone (lab row 12).

Measured on the lab: `sp_articlefilter` with a new clause rewrites the procedure and `filter_clause` but leaves the view on the old clause; with NULL it drops the procedure and also leaves the view (panel, verified twice). The reader warns when it finds a filter clause without a filter procedure, a filter procedure with a NULL clause, or a view whose definition does not contain the article's clause.

Subscriptions:

- Push subscriptions (`sp_addsubscription`, `sp_addpushsubscription_agent`) run at the publisher, in the publication database, not at the distributor (in the distribution database they fail with 14013, panel); the jobs they create live in `msdb` at the distributor.
- Pull subscriptions: `sp_addsubscription @subscription_type = N'pull'` at the publisher, then `sp_addpullsubscription` and `sp_addpullsubscription_agent` at the subscriber, with `@subscription_type = N'pull'` always passed: left out, `sp_addpullsubscription` creates an anonymous subscription on 2022, out of scope, while the publisher records a named pull (panel); the 2019 source raises 20016 instead. Dropping one: `sp_droppullsubscription` at the subscriber and `sp_dropsubscription` at the publisher, order and leftovers to confirm by the campaign.
- A subscription to a subset of articles (`articles:` in the file) is only possible on a publication without `immediate_sync` and with `native` or `character` sync. On the others, `plan` refuses the file: `sp_addsubscription @article` fails with 14100 on concurrent sync, whether or not `immediate_sync` is set, and with 14122 on `immediate_sync` with native or character sync (panel, second round).
- A whole subscription is dropped by one call, `sp_dropsubscription @article = N'all'` (panel, second round, two readers; `@article = NULL` is refused with 14043).
- A subscription that covers fewer articles than its publication, on a publication where a subset cannot exist, is an intermediate state of the strategies above (an article whose subscription was dropped and which is not yet dropped; an article added and not yet subscribed). The plan completes it with the cheapest step from the observed state: dropping the article, or extending the subscription with `@article = 'all'`, which delivers only the missing article. It never answers it with a drop and re-creation of the subscription.
- Drop and re-add of subscriptions (forced by `independent_agent`, `enabled_for_het_sub`, `allow_push = false`, see below): the subscriptions are re-added with snapshot initialization and the plan announces a reinitialization. For a subscription whose `initialization` is "replication support only", backup or LSN, re-adding it the same way would lose the changes made between the drop and the re-add (panel); the plan refuses, with the reason, and leaves it to the DBA. My call.

Publication properties:

- Property chains: `allow_anonymous` needs `immediate_sync` needs `independent_agent`; `compress_snapshot` needs `alt_snapshot_folder`; `enabled_for_internet` needs `ftp_address`; `replicate_partition_switch` needs `allow_partition_switch`. Enable from the bottom up, disable from the top down (measured).
- `independent_agent` cannot change while the publication has subscriptions (error 20013): the plan drops the subscriptions, sets `immediate_sync = false` first where it is true (21022 otherwise), changes `independent_agent`, and adds the subscriptions back with `@article = 'all'` and their agents (panel: executes). Cost: drop and re-add.
- Properties no flag can change while subscriptions exist (`enabled_for_het_sub`, `allow_push = false` with push subscriptions): the same drop and re-add, or a refusal with the reason when the file asks for something impossible.

Agents and profiles:

- No `sp_add*_agent` procedure takes a profile (panel, from `sys.all_parameters` and the sources in `stored-procedures/`): an agent is created on the default profile of its type, then bound to the file's profile by `distribution.dbo.sp_update_agent_profile @agent_type, @agent_id, @profile_id`. The procedure lives in `msdb` and checks that it runs in the distribution database: called as `msdb.dbo.sp_update_agent_profile` it executes in `msdb` whatever the current database and refuses with 21482, which the second review round took for a refusal of the binding itself; called through the distribution database it succeeds (verified on 2022 after the plan review, campaign rows `PRF.*`). Profiles are created before the agents that use them.

### Order

The order of section 6 of the analysis, extended for creation and corrected by the panel:

1. distributor: create what is missing, skipping what exists (`sp_adddistributor`, run in `master` with `@distributor`, fails with 14099 when a distributor exists, panel), or change it (`sp_changedistributiondb`, `sp_changedistpublisher`);
2. user profiles: create and change;
3. publication database: `sp_replicationdboption publish` (idempotent, panel), log reader agent;
4. drop subscriptions to removed articles, and subscriptions removed from the file;
5. drop removed articles, then removed publications (`sp_droppublication` fails with 14005 while any subscription remains);
6. change publication properties, in the order of the chains above;
7. change kept articles: properties, then filters and columns, then views, as in "Filters and views";
8. add publications and their snapshot agents, then articles, filters, columns and views;
9. add subscriptions and their agents (push at the publisher; pull at the publisher and the subscriber), or extend existing subscriptions to new articles;
10. bind agents to profiles, set agent schedules;
11. drop user profiles no agent uses any more.

The builder may refine it; the plan's tests must prove that the order satisfies every dependency measured.

## apply

`sqlrepl apply -f desired.yaml`:

1. recomputes the plan against the live servers, so it never runs a stale plan;
2. prints it, with the count of costly operations, and asks for `yes` (skipped with `-auto-approve`; refused when there is no terminal and no `-auto-approve`);
3. runs the operations in order, each on its server, logging each statement before it runs; all the statements for one server run on one pinned connection (`*sql.Conn`), never on the pool, because the transaction check below is session state;
4. after a failed statement, checks `@@TRANCOUNT` on that same connection and rolls back what the procedure left open (lab row 11; a refused `sp_droparticle` leaves two levels open, panel), then stops;
5. on success, starts the snapshot agent of each publication whose snapshot was invalidated or that has a new or reinitialized subscription, then waits until the snapshot is generated and delivered to the subscriptions concerned (agent history), up to a timeout (`-wait`, default 30 minutes; `-wait 0` does not wait). It reports what was delivered; a snapshot not delivered within the timeout is reported as started and unconfirmed, and `apply` exits with a distinct status. My call: "the data at the subscriber is what the file describes" is only claimed for what was confirmed.

On failure, `apply` reports what ran, what failed with the server's message, and what remains. It does not undo. Running `plan` again reads the server as it is and plans from there; the operations already done are no longer in it, the intermediate states of the strategies are completed (see "Subscriptions"), and a snapshot invalidated by an operation that ran but never regenerated is seen as pending in the observed facts, which gives the plan an operation to start it (panel, second round: otherwise the next plan has nothing left to do and the snapshot stays invalid). This is why convergence is a requirement.

`apply` does not wrap the operations in one transaction: several procedures create jobs, databases or linked servers, some on other servers, and `sp_addsubscription` refuses to run inside a transaction (error 15002, panel).

The panel met a deadlock (1205) during a sequence of subscription drops and a "only one Log Reader Agent or log-related procedure" message (18752) during `sp_droppublication`. `apply` treats them as failures, stops, and lets the next `plan` resume; whether a bounded retry is safe is measured by the campaign. My call.

## Snapshot runs and their report

Rudi's request, 2026-11-11: a snapshot that does not block the publisher, and a report of each snapshot that can be exported.

### Blocking

How long a snapshot blocks writers on the published tables is decided by the publication's `sync_method`, which the file already carries:

- `native` and `character` hold a shared lock on each table while it is copied, so writers to that table wait for the whole copy;
- `concurrent` and `concurrent_c` lock only briefly at the start and the end of the generation (transactional publications only; refused on a snapshot publication with 22547, campaign row `SNAP.P12`);
- `database snapshot` and `database snapshot character` read a database snapshot and take no lock on the published tables; they need the Enterprise or Developer edition, which `plan` checks as a precondition.

`plan` warns when a transactional publication of the file uses `native` or `character`, with the cost of changing it: on an existing publication `sync_method` needs a reinitialization (analysis section 5). The omitted value stays the SQL Server default (`native`), per "Omitted properties". My call: a warning, not a changed default, because the file is the whole truth and a silent default would contradict the export.

### The report

Every snapshot that `apply` starts (step 5), and every snapshot started by `sqlrepl snapshot -publication <name>`, produces a report. The command `sqlrepl snapshot` starts the snapshot agent of one publication, waits like `apply` (`-wait`), and writes the report; it changes no configuration, so it needs no plan. The report is written as one self-contained HTML file (no external script, style or font, so it can be mailed or attached) next to a JSON file with the same data, which the GUI reads later. Option `-report <path>`; by default `snapshot-<publication>-<UTC timestamp>.html` in the current directory.

What the report holds, and where each value comes from:

- the run: publication, `sync_method`, the edition, start and end of the generation and of each subscription's delivery (snapshot and distribution agent history after a mark taken before the start);
- per article: rows bulk copied and the time it took at each subscriber (distribution history, the "Bulk copied data into table" lines the campaign already reads), and the files generated with their size;
- total size of the snapshot folder of this run, read on the distributor with `sys.dm_os_enumerate_filesystem` for the default folder; an alternate or UNC folder the distributor cannot list is reported as not readable, never guessed;
- blocking: the sessions that waited on a lock held by the snapshot agent, and the sessions the agent waited on, with the object, the wait type and the longest wait. They are sampled from `sys.dm_os_waiting_tasks` and `sys.dm_exec_requests` on the publisher every second during the generation, for sessions whose blocker or blocked session is the snapshot agent's (identified by its `program_name`). A wait shorter than the sampling interval can be missed, and the report says so. My call: sampling rather than the `blocked_process_report` event, which needs the server option `blocked process threshold`; `sqlrepl` never changes a server option for a report. When that option is already set, the report also reads the event from a session it creates and drops for the run;
- agent errors and retries during the run (agent history, `MSrepl_errors` after the mark).

The report is read-only for the servers except for the snapshot itself and the sampling. What each source returns on each `sync_method`, and whether the sampling sees the blocking that a writer measures, are campaign item 13.

## Secrets

The file holds no secret. A password appears as a `password_secret` name. At `plan` and `apply` time, `sqlrepl` reads the value from the environment variable of that name, after loading an optional `.env` file (default `./.env`, `-env` flag), where the real environment wins. The loader is the stdlib-only `internal/dotenv` of `~/Sources/Repos/atelier/outils/sylloge/internal/dotenv/`, copied, not imported. `plan` reports every secret the plan needs and whether it is set; `apply` refuses to start while one is missing.

The model gains a secret name for every password parameter of every in-scope procedure, which the builder lists from `sys.all_parameters`; among those it lacks today (panel): the job account (`@job_login`, `@job_password`) of every agent, the distributor credentials of a pull agent (`@distributor_login`, `@distributor_password`), the `distributor_admin` password of a remote distributor (`sp_adddistributor @password`), the SQL login of `sp_adddistributiondb` when `@security_mode = 0` (error 21694 otherwise), the distributor credentials of the snapshot agent (`sp_addpublication_snapshot @distributor_login`, `@distributor_password`), and those already named (subscriber, publisher, `MSdistpublishers`, FTP).

Secrets never appear in the T-SQL that is printed or logged. `apply` passes them as parameters of `sp_executesql`; `plan -sql` prints the same statement with the parameter names and a comment naming the secret, so the printed text is the executed text without the values. My call.

Passwords are set when an object is created. `plan` cannot read them, so it never plans a password change; `apply -rotate-secret NAME` changes the password of every object that uses that secret, as an explicit action. My call.

## Servers and connections

Servers are named in the file by their SQL Server name (`@@SERVERNAME`), which is what replication stores and may not resolve from where `sqlrepl` runs (the lab's `REPLLAB`). How `sqlrepl` reaches each server, and with which credentials, is given at run time, never in the file: the builder chooses between flags (`-server REPLLAB=tcp:127.0.0.1,11980`) and a connections file kept outside the repository. `sqlrepl` connects to the publisher, the distributor, and each subscriber that has a pull subscription or whose database must be checked.

## Engine as a library

The GUI will drive the same engine. Constraints on the builder:

- the comparison and the plan are pure functions of the desired configuration, the current configuration, the observed runtime facts and the cost table, with no database access, so that the GUI can recompute costs on every edit and the tests can cover them without a server;
- reading the servers, computing the plan, and executing it are separate packages;
- the plan is a Go value that serializes to JSON without loss; `-json` and the GUI use the same serialization;
- the CLI only parses flags and prints.

## Renaming

`replcfg` becomes `sqlrepl`: the command (`cmd/sqlrepl`), its usage and messages, the environment variables (`SQLREPL_PASSWORD`, `SQLREPL_TEST_DSN`), and the documentation. The Go module path stays `github.com/rudi-bruchez/sqlserver-replication`, the repository's name. My call; the rename is the first task of the plan.

## Extending the model and the export

The model covers every parameter of the in-scope procedures (Rudi's decision), so that "whole truth" holds down to properties: among others `allow_partition_switch`, `replicate_partition_switch`, `enabled_for_het_sub`, `enabled_for_internet`, the distribution database file locations and sizes, the initialization parameters (backup device and location, LSN), the secret names above. The builder lists the parameters of each procedure from `sys.all_parameters` on each supported version and maps each to a field or to a documented exclusion.

The export must read what the plan manages, since the plan compares against it:

- an instance with no replication, as an empty configuration;
- pull subscriptions: at the publisher (`syssubscriptions.subscription_type = 1`) and at the subscriber, where the agent's settings are in `MSsubscription_properties` and `MSreplication_subscriptions` is written by `sp_addpullsubscription`, not by the agent (panel); today the export warns and skips them, so no plan on a database that has one could converge (panel);
- snapshot publications (`repl_freq = 1`): today reported under `warnings`;
- every profile of the distributor and its use by the agents of every database;
- the observed runtime facts the planner takes as input;
- the definition of each synchronization view, enough to check it against the clause and the columns.

## Measurement campaign

The first block of the implementation plan, before the planner (Rudi's decision). Each item becomes a script under `lab/`, like `measure-matrix.sql`, written so that it runs unchanged on every supported version. The campaign runs on 2022 first, and the engine is built on those results; the scripts are then replayed on 2019 and 2025, and the support claim for those versions holds once they have run and their differences are in the cost table (Rudi's decision). Results are recorded per version in `lab/README.md` and in the cost table:

1. the 20607 condition (`immediate_sync` with a generated snapshot, measured on 2022 for `sp_addarticle` and `sp_droparticle`) for every procedure that takes the flag, on each version;
2. drops: `sp_droparticle`, `sp_dropsubscription` per article, `sp_droppublication`, their flags and costs, on each kind of publication;
3. concurrent sync without `immediate_sync`: extending a subscription with `@article = 'all'` (measured on 2022: only the new article is delivered), on each version;
4. dropping an article and adding it back, on each kind of publication;
5. subscription changes (`sp_changesubscription`, `sp_changesubscriber`), agent changes (`sp_change*_agent`, schedules, binding an agent to a profile through `distribution.dbo.sp_update_agent_profile`), the lifecycle of a shared distribution agent, distributor changes (`sp_changedistributiondb`, `sp_changedistpublisher`, `working_directory` included);
6. pull subscriptions: creation, change, drop, and their agents;
7. snapshot publications: the whole matrix;
8. initialization by "replication support only", backup and LSN;
9. the complete defaults of every parameter of every in-scope procedure, in every context, unqualified procedure names in a non-`dbo` schema, and the server and database each procedure must run in;
10. transient errors during drops (1205, 18752) and whether a retry is safe;
11. the filter and view rules above, as a regression measure, including whether `sp_articlecolumn` rebuilds an existing view.
12. the scope of a snapshot generation after an article is added, for each combination of `immediate_sync` and `sync_method`: which tables the snapshot agent generates files for (files in the folder, snapshot history), which existing tables it locks and for how long (a writer on an existing table, timed, during the generation), and the duration; then the `-defer-full-snapshot` sequence: the flags of each step, what it generates, and what a subscriber added after `immediate_sync` is restored receives;
13. the sources of the snapshot report: what the snapshot and distribution histories and `sys.dm_os_enumerate_filesystem` return on each `sync_method`, and whether one-second sampling of the waiting tasks sees the blocking a timed writer measures, under `native`, `concurrent` and `database snapshot`.

Items that add subscriptions (3, 6, 8 among others) cannot be measured inside a rolled-back transaction, since `sp_addsubscription` refuses to run in one (15002): they run on objects of their own, created and removed by the script.

The lab container runs with `MSSQL_MEMORY_LIMIT_MB = 4096`: at 2048 it stopped under memory pressure (error 701) while five reviewers ran scenarios on it (panel). My call.

## Testing

- Unit tests for the normalization, the comparison, the cost table and the ordering, with configurations built in Go; no server.
- Integration tests on the lab container, gated by an environment variable like `TestQueriesParse`. The central scenario: start from an instance with no replication, apply a file, export, check that the export normalizes to the file and that `plan` is empty. Then a set of change scenarios, one per strategy above, each checking the plan's operations and costs before applying, and convergence after.
- For every scenario that touches a filter or columns, the test also checks the data: after the snapshot and after changes made at the publisher, the subscriber holds exactly the rows and columns the file describes. The export cannot see a synchronization view out of step with its filter (panel), so convergence of the configuration alone does not prove it.
- The integration tests run on the 2019, 2022 and 2025 images before the support claim holds.
- Each strategy and each cost entry has a test that fails when the rule is broken. The builder breaks each rule once to watch its test fail.

## Left to the builder

- Package layout below the constraints of "Engine as a library".
- How the model marks omitted properties (pointers, a separate presence set, or defaults applied at load).
- The connection mapping (flags or a local connections file), within the rule that it stays out of the configuration file.
- The text layout of the human summary.
- The exact list of preconditions `plan` checks, beyond those named here.
