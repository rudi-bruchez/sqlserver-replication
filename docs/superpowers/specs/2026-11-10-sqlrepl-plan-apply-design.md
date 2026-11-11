# sqlrepl plan and apply

Design of the declarative engine of `sqlrepl`: describe a SQL Server replication in a file, see what it takes to get there, and get there. Written on 2026-11-10 from a conversation with Rudi, then revised the same day after a builder check and two rounds of external review (Mistral Large and GLM through Vibe, codex, Claude readers), whose findings were run on the lab. The parts marked "my call" are decisions taken while writing, to be checked.

Reference material this design relies on, and does not repeat:

- `docs/analysis/step-1-analysis.md`: where the configuration lives, how it is coded, the measured impact matrix (section 5), the order of operations (section 6);
- `lab/README.md`: the lab container, the measurement campaign and its results, one section per campaign script (rows 1 to 12 are the first measurements);
- `CLAUDE.md`: the traps already paid for in the reader.

Facts established by the review rounds are cited as "panel", with the error number or the measurement. The measurement campaign has since run on SQL Server 2022 CU27 (see "Measurement campaign"). Its rows are cited as `<script> <case id>`, for example `05-snapshot-flag S7.O1`, and are read in `lab/results/2022/<script>.txt`. Where a row contradicted a panel statement, the rule below follows the row.

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
| table article, transactional publication, `native` or `concurrent` | `schema_option 0x30073`; commands `CALL [dbo].[sp_MSins_…]`, `SCALL [dbo].[sp_MSupd_…]`, `CALL [dbo].[sp_MSdel_…]` (an unqualified procedure name in a command is stored with `[dbo]`, even for a source table in another schema, `11-defaults` context `table.non-dbo-schema`: the file writes the schema it means, and the reader compares against the stored one); destination owner: the source schema (`sales.S1` gives `sales`); status 16 (parameterized); `pre_creation_cmd` drop |
| table article, transactional publication, `character` | `schema_option 0x30073`; commands `SQL`; destination owner NULL |
| table article, snapshot publication | `schema_option 0x30071`; commands `SQL`; destination owner: the source schema |
| schema-only article (view, procedure, function) | `schema_option 0x1`; `pre_creation_cmd` drop; destination owner `dbo`; status 16 |
| publication | `sync_method native`, `retention 336`, `independent_agent 0`, `immediate_sync 0`, `allow_push 1`, `allow_pull 0`, `replicate_ddl 1`, `allow_subscription_copy 0`, `allow_initialize_from_backup 0`, `snapshot_in_defaultfolder 1`, `status inactive` |

The table is a sample: the complete defaults, for every parameter of every in-scope procedure, are the rows `D.<procedure>.<context>.<parameter>` of `11-defaults` and, for the distributor procedures, of `distributor-defaults`. A value printed `pre-existing(...)` in those files was in place before the call and is not a default. The default of `sp_addsubscription @subscriber_type` is not measured (the lab's subscriber is registered beforehand, `D.sp_addsubscription.push.@subscriber_type`); the builder leaves it out of the defaults table, so a file that omits it is refused as unmeasured until the campaign measures it. The consequence is wide: until then, a hand-written subscription must state the subscriber type. Item 19 measures it in one call, on a fresh subscriber that is not registered yet. The builder's defaults table is keyed by object type and by the properties the default depends on (publication type, `sync_method`, article type), each entry with its source. Where a property requires another, an omitted prerequisite takes the value the declared property requires, not the procedure default: `immediate_sync` needs `independent_agent` (`sp_addpublication @immediate_sync = 'true'` alone is refused with 21022 and does not fill it, panel), a pull subscription needs `allow_pull` and a push subscription `allow_push` on its publication (`sp_addsubscription` returns 20012 otherwise, panel). Otherwise a short file would normalize to a combination the server refuses.

Three properties have no default and must be written in the file: `status` of a publication, `initialization` of a subscription, and the name of a row filter's procedure (`sp_articlefilter` refuses a NULL `@filter_name`, 14043; the engine never invents one, and never falls back on `sp_addarticle @filter_clause`). My call. The procedure default for `status` is `inactive`, and a short hand-written file applied to an active publication would deactivate it with a cost the plan would present as online (panel).

The export keeps writing every property, so that an exported file is explicit.

### What is not compared

- Names that replication generates: job names, generated synchronization views (`syncobj_0x…`), generated command procedures when the file does not name them.
- Values derived from other properties: article status bits `0x8` and `0x20` when `schema_option` has `0x8` (lab row 3).
- Runtime state: subscription status, `immediate_sync_ready`, history, and the `active` bit (`0x1`) of an article's status, which the snapshot sets once delivered and no procedure sets (panel).
- Schedule dates and times set at creation (`start_date` is the creation day) when the file does not declare a schedule. A schedule left out of the file means the schedule the procedure creates (daily every 5 minutes for a snapshot agent, `11-defaults` `D.sp_addpublication_snapshot.transactional.@frequency_*`; continuous for the distribution agent of a push subscription, `D.sp_addsubscription.push.@frequency_type` 64), compared on its frequency fields only. A declared schedule is compared in full.
- The agent command line (`command`). The export shows it for information, the plan ignores it, and warns when it carries parameters beyond those the procedures generate; agent tuning belongs in profiles. My call.
- The existence of a shared distribution agent: it is created with the first subscription that uses it and disappears with the last, its job with it (`07-changes` `SHR.after1`, `SHR.after2`); its properties are compared while it exists. My call.
- The `initialization` of an existing subscription. It is a creation parameter: it decides how the subscription is created, and how it is re-created when a plan must drop and re-add it. Changing it alone plans nothing, with a note.

### Names

Server names are compared case-insensitively (`syssubscriptions.srvname` is stored in upper case). Command procedures are always written by the engine schema-qualified, in `sp_addarticle` and in `sp_changearticle` alike: the two procedures store an unqualified name differently (`sp_addarticle` qualifies it with `dbo`, `sp_changearticle` keeps it unqualified, panel, on 2022 and 2025), so passing the file's text through would never converge. Normalization qualifies an unqualified name in the file with the schema `sp_addarticle` would use (`dbo`, whatever the schema of the source table: for a table of the schema `m_s`, `CALL m_ins` is stored as `CALL [dbo].[m_ins]` and the generated procedures are `[dbo]`-qualified too, `11-defaults` `D.sp_addarticle.table.non-dbo-schema.*`).

## Shared distributor objects

The distributor serves other publication databases the file does not see. For the objects that belong to the distributor rather than to the database (Rudi's decision):

- the distributor, the distribution database, its retention, the `MSdistributor` properties and user agent profiles can be created and changed by the file;
- they are never dropped while something uses them. A user profile is dropped only when it is absent from the file and no agent of any database at that distributor uses it; which profile is the default of its agent type is a distributor-wide setting;
- a change to a shared object is marked "shared" in the plan, with the list of the other publication databases the distributor serves. Two files that disagree on a shared value therefore each show the change as shared when they are planned; `plan` cannot see the other file, so it reports the conflict by showing that the server's value differs from what this file wants on a shared object. My call on the mechanism.

The reader must read every profile of the distributor and which agents use it, not only those used by this database (today `collectProfiles` reads only the latter, panel).

## plan

`sqlrepl plan -f desired.yaml` reads the current state, normalizes the desired file, compares them, and prints the plan. It runs only `SELECT` statements and read-only checks.

### Inputs

The comparison takes three inputs: the desired configuration, the current configuration (the reader's `model.Config`), and the observed runtime facts the costs depend on: per subscription its status and the articles it actually covers, per publication whether a snapshot has been generated and is still valid (`immediate_sync_ready`), whether a snapshot is pending, and per distribution agent its state (running or stopped, and its last error since the latest generation of the publications it serves), which the warning below needs. My call: the measured costs depend on these facts (analysis section 5), so they are an explicit input rather than a guess; the GUI supplies them the same way.

A snapshot is pending when a subscription awaits a run of the snapshot agent: a subscription not yet initialized, a subscription marked for reinitialization, or a subscribed article that no run has generated yet. `syssubscriptions.status` 1, or a subscribed article whose `sysarticles.status` lacks the active bit `0x1`, shows it. Both are set by the generation, not by the delivery, in the two contexts measured, a `character` publication without `immediate_sync` and a `database snapshot` publication with it: with the distribution agent stopped, a run set the new article's subscription to status 2 and its active bit while nothing reached the subscriber, and the delivery came only when the agent was started (`15-snapshot-scope` `E.extended`, `E.generated_undelivered`, `E.delivered`; in the round 1 results, `git show 8db6060:lab/results/2022/15-snapshot-scope.txt`, `A.imm.dbsnap` ended at status 2 after a failed delivery). `sp_addsubscription` on an `immediate_sync` publication with a ready snapshot also sets status 2 at once, with nothing delivered (`05-snapshot-flag` `S7`). These columns therefore show what awaits a generation, and a generated but undelivered snapshot reads as delivered. The first version of this definition said that only a delivered snapshot sets the active bit; `E.generated_undelivered` contradicts it.

A snapshot generated and not yet delivered is not measured. The candidate first proposed, comparing the folder named by the distribution agent's last "Delivered snapshot from the '...\<timestamp>\' sub-folder" line (it names the run's folder, `16-snapshot-report-sources` `RS.*.distribution_history`) with the folder of the latest generation, fails on an `immediate_sync` publication: every run makes a new folder that the existing subscriptions never receive, so the two differ for a subscription that awaits nothing (read-only observation, `lab/README.md`, "Observed outside the campaign"). A second candidate, the snapshot commands in `distribution.dbo.MSrepl_commands` (type with the bit `0x80000000`) for one of the subscription's articles beyond the last `xact_seqno` of its distribution agent's history, has a false positive: every scheduled run of `SalesPub` writes new snapshot commands for a subscription that awaits nothing, and the agent's history `xact_seqno` passes them only at its next history write, never while the agent is stopped (read-only observations of the task 12 review and of `lab/README.md`, "Observed outside the campaign"). Proposed, unmeasured: the same test restricted to the commands the distribution agent itself would deliver to that subscription. In the 2019 source of `sp_MSget_repl_commands` (`stored-procedures/`), the agent takes a snapshot command for a subscribed article only when its `xact_seqno` lies between that article's `distribution.dbo.MSsubscriptions.subscription_seqno` and `ss_cplt_seqno`. A subscription would then await a delivery when one of its articles has snapshot commands in that window beyond the agent's last history `xact_seqno`. A read-only reading on the lab (`lab/README.md`, same section) found all of `SalesPub`'s scheduled snapshot commands outside its subscription's window, so the restricted test gives "nothing awaited" there whatever the agent's watermark; that reading is one delivered subscription, not the control. The true positive (a generation for a subscription that awaits it, agent stopped) and the negative control (an `immediate_sync` publication whose subscription is fully delivered, agent stopped, one more run of the snapshot agent: the test must say nothing is awaited) are campaign item 14. Until it is measured, `plan` cannot see a generated, undelivered snapshot. It reports for each subscription the state of its distribution agent (running, stopped, or its last error since the latest generation), warns when that agent is not running or has failed, and plans nothing for it. `apply` step 5 is not affected: it waits for the delivery of the run it started, which it recognizes by that run's folder.

An `immediate_sync` snapshot that is invalid (`immediate_sync_ready = 0`) while no subscription awaits it is not pending: the plan reports it as "full generation deferred to the next run of the snapshot agent" and plans nothing for it. Otherwise the state that `-defer-full-snapshot` leaves would read as pending, `apply` step 5 would start the full generation at once, and the option would cost exactly what it claims to save (review of e220523, three readers). The operations that invalidate a ready snapshot without marking anything leave exactly that state: dropping an article, `alt_snapshot_folder`, `immediate_sync` false, `allow_anonymous` false, and a `sync_method` change between `native`, `character` and `database snapshot` (`15-snapshot-scope` `C.*.droparticle`, `C.*.alt_snapshot_folder`, `C.*.immediate_sync_false`, `C.character.sync_method`, `C.dbsnap.sync_method`, `B.native_anon.1a`, `B.concurrent_anon.1a`: `immediate_sync_ready` 0, every status 2, no inactive article). This is consistent with "full generation deferred": none of them leaves a subscription without data it had or awaited. For those that leave `immediate_sync` on, the next run regenerates every article, as `B.*.5b` shows for the deferral; after `immediate_sync` false, the next run generates only what is awaited, as for any publication without it (`A.non.*`). The others mark what they invalidate and read as pending: adding an article, an article property, a filter, a view, a column, and a `sync_method` change from or to `concurrent` or `concurrent_c` (`C.*.addarticle`, `C.*.schema_option`, `C.*.articlefilter`, `C.*.articleview`, `C.*.articlecolumn`, `C.native.sync_method`, `C.concurrent.sync_method`, `C.concurrent_c.sync_method`).

The reader keeps apart two kinds of findings that today share one `warnings` list: out-of-scope features (merge, peer-to-peer, updatable or anonymous subscriptions, non-SQL Server peers), for which `plan` refuses the database, and incomplete in-scope objects (a publication without its snapshot agent, a subscription not covering every article of a publication where that cannot exist), which are part of the current state and which the plan repairs. A blanket refusal would block the repair of an interrupted `apply` (panel).

The reader returns an empty current configuration for an instance with no distributor, or a database not enabled for publishing, instead of an error (today `readDistributor` fails when the publisher is not registered, panel). That is the starting point of every creation.

### What a plan is

A plan is an ordered list of operations. Each operation has:

- the object it acts on (distributor, publication, article, subscription, agent, profile) and the kind of change (add, change, drop);
- the property changes it carries, before and after;
- the server and database it runs on, from a table in the code with one measured entry per procedure (`12-contexts` and `distributor-defaults`, rows `X.<procedure>.<database>`): `sp_adddistributor` and `sp_adddistributiondb` in `master` (5001 elsewhere, panel), `sp_addsubscription` and the `sp_add*_agent` procedures of push subscriptions in the publication database at the publisher, the pull procedures in the subscription database at the subscriber, and so on;
- the exact T-SQL, with secrets as named parameters;
- its cost, one or more of: online, start of a pending snapshot, new snapshot, reinitialization of named subscriptions, drop and re-add of named subscriptions, subscriber data replaced, subscriber object left behind, shared object changed;
- the reason for that cost, with its source (matrix row, lab row, panel measurement);
- warnings.

The plan as a whole also lists the secrets it needs and whether each is set, the preconditions it checked (subscriber database exists, published table exists and has a primary key for a transactional article, error 14088 otherwise, snapshot folder visible, no subscription declared on a publication declared inactive, error 21000 otherwise), and the agents `apply` will start.

Output: a human summary (one line per operation with its cost, then the totals), `-sql` for the T-SQL, and `-json` for the plan as data, which the GUI and the tests consume. A plan is never saved to be applied later; `apply` always recomputes it. My call.

### Costs and unmeasured changes

The cost of each change, and the flags it needs, come from a cost table in the code, one entry per change and context, each with its source. Only measured entries exist (Rudi's decision). The server asks the flags even for a call that sets a property to the value it already has (`09-snapshot-pub` `SNAP.A22` f01, `SNAPI.A22` f11), so a normalization error does not only fail to converge: it costs a reinitialization at every `apply`. The normalization tests are therefore part of the cost rules. a change that has no measured entry is refused by `plan` with "cost of <change> not measured", never guessed and never sent to the server to find out. The measurement campaign fills the table before the planner is written.

The plan passes exactly the flags the entry says are needed, never both by default.

### Strategies

Each rule comes from a measurement: the analysis, the panel, or a campaign row. The campaign has settled the entries the first version left open; what it did not settle is named in the rule and listed under "Measurement campaign".

The publication properties a strategy depends on (`immediate_sync`, `sync_method`, whether a snapshot is generated) are those in effect when the operation runs: the target values for operations ordered after the publication property changes (step 6 of the order), the current ones before. My call.

Articles:

- Add an article to a publication that keeps its snapshot (`immediate_sync`): `sp_addarticle` with `@force_invalidate_snapshot = 1` when `immediate_sync_ready = 1`, with no flag otherwise (`D.imm_native.addarticle`, `D.imm_concurrent.addarticle`, f00 with ready 0); existing subscriptions get it at once; the next snapshot is regenerated for the whole publication but only the new article is delivered (lab row 9; under every `sync_method`, `15-snapshot-scope` `A.imm.*`). No extension is emitted: `sp_addarticle` has already subscribed the existing subscriptions (`C.*.addarticle`, `D.imm_native.addarticle`). Every addition measured had at most one article marked; `sp_addarticle` on an `immediate_sync` publication whose every subscription row is marked (a `sync_method` change from or to `concurrent` or `concurrent_c` in step 6, then the addition in step 8) has no row, and `plan` refuses that combination with the message of the extension gap below, until campaign item 15 measures it. Cost: new snapshot.
- Add an article to a publication without `immediate_sync`, `native`, `character` or `database snapshot` sync: `sp_addarticle` with no flag, then `sp_addsubscription @article` for each existing subscription (lab row 10; `15-snapshot-scope` `A.non.native`, `A.non.character`, `A.non.dbsnap`). Cost: snapshot of the new article; the run generates and locks that table alone.
- Under `database snapshot`, with or without `immediate_sync`, the delivery of the just-added article failed intermittently with "Could not find stored procedure 'dbo.sp_MSupd_dbom_t3'" (round 1 results `A.imm.dbsnap`, and `A.non.dbsnap` in two development runs), and the variants built to reproduce it all delivered (`F.dbsnap_before`, `F.dbsnap_during`, `F.dbsnap_none`, `F.imm_dbsnap_1` to `_3`). Its cause is unknown. It is an open risk, campaign item 17: `apply` step 5 reports such a delivery as started and unconfirmed, with the agent's error.
- Add an article to a publication without `immediate_sync`, `concurrent` or `concurrent_c` sync (the most common transactional configuration): `sp_addsubscription @article = '<name>'` is refused with 14100, "Specify all articles when subscribing to a publication using concurrent snapshot processing" (panel); the extension is `sp_addsubscription @article = 'all'`. Measured: only the new article is delivered, existing articles are not sent again (panel, second round). Cost: snapshot of the new article. The run generates the new article alone under `concurrent` and `concurrent_c` too (`15-snapshot-scope` `A.non.concurrent`, `A.non.concurrent_c`), which settles the disagreement of the review of e220523.
- Extending the existing subscriptions to a new article, whatever else the plan changes. On an `immediate_sync` publication the plan emits no extension: `sp_addarticle` has already subscribed them, and an explicit extension is refused, by name with 14122 and with `@article = 'all'` with 14058, "already exists" (`15-snapshot-scope` `D.imm_native.extend_rule`, `D.imm_native.extend_all`, `D.imm_concurrent.extend_rule`). On a `concurrent` or `concurrent_c` publication without `immediate_sync`, the extension is `@article = 'all'`; a named one gets 14100 (`D.non_native_pub.extend`, `D.non_concurrent_pub.extend`). Otherwise it is by name. None of these refusals comes from a reinitialization mark. They repeat after the snapshot, with nothing marked (`D.imm_native.extend_after_snapshot`, `D.imm_concurrent.extend_after_snapshot`). Without `immediate_sync`, the extension is accepted with one article marked by a change in the same plan (`D.non_native.extend_rule` by name, `D.non_concurrent.extend_rule` with `'all'`) and with every subscription row marked by a `sync_method` change (`D.non_native_pub.extend`, `D.non_concurrent_pub.extend`, on a publication that is `concurrent` or `concurrent_c` at that moment), and the next snapshot delivers the marked and the new articles (`D.*.snapshot`). This replaces the refusal of the first version ("measured refused, 14058 under `native` and 14100 under `concurrent`"), whose 14058 was the duplicate on an `immediate_sync` publication and whose 14100 was the static rule above. Not measured: a named extension on a `native` or `character` publication whose every row is marked, which is what a plan that changes `sync_method` from `concurrent` or `concurrent_c` to `native` or `character` and adds an article produces in this order (step 6, then steps 8 and 9). The other order is measured and works (`D.non_native_pub.extend_then_change`: the article added and extended with `'all'` while the publication is `concurrent`, then the change to `native`), but it is not the order of "Order". `plan` refuses that combination with "cost of extension after a publication reinitialization not measured" and asks for two plans, until campaign item 15 measures it.
- Add an article to an `immediate_sync` publication without regenerating every table (Rudi's request, 2026-11-11). The rule above regenerates the snapshot of the whole publication: every published table is read again, under the locks its `sync_method` takes, even though only the new article is delivered. The option `-defer-full-snapshot`, given to `plan` and to `apply` alike (`apply` recomputes the plan, so the choice of path must reach it too), replaces it with this sequence:
  1. `sp_changepublication` `allow_anonymous` to false when it is true, then `immediate_sync` to false. Both calls are accepted with no flag; the first of them drops `immediate_sync_ready` from 1 to 0, and no subscription status changes (review of e220523, three readers; `15-snapshot-scope` `B.*.1a`, `B.*.1b`): the snapshot is invalidated without the server asking for a flag, so the plan marks the cost from the observed `immediate_sync_ready`, not from the flags.
  2. `sp_addarticle` and the extension of the existing subscriptions, by the rules for a publication without `immediate_sync`: no flag, the extension by name under `native` and `'all'` under `concurrent`, the new article at status 1 (`B.*.2a`, `B.*.2b`).
  3. An operation of its own, "generate and wait": start the snapshot agent and wait until its run has ended, up to `-wait`. The run generates and delivers the new article alone, and every status is then 2 (`B.*.3`).
  4. Restore `immediate_sync`, then `allow_anonymous`: no flag, `immediate_sync_ready` stays 0, every status stays 2 (`B.*.4a`, `B.*.4b`).

  The wait in step 3 is required. Restored while the agent was still starting, `immediate_sync` made the run generate every article again, although only the new one was delivered (review of e220523, three readers; `B.native_race.race` and `B.concurrent_race.race`, restores committed 798 and 558 ms before the agent's first history line, which generated `m_t1` to `m_t3` and delivered `m_t3`). Only that case is measured: a restore committed during the generation is not. The wait makes the question moot for this sequence, since the restore comes after the run has ended. When the wait times out or the run fails, `apply` stops with `immediate_sync` off. The next `plan` shows the restore as the remainder of a deferral and announces its cost: the next generation covers every article.

  The full generation is deferred, not avoided. After the restore the publication has `immediate_sync = 1` and `immediate_sync_ready = 0`. The next run of its snapshot agent, whatever starts it, generates every article. A subscription added after the restore awaits every article, and that run delivers them all to it and nothing to the subscriptions that already had them (`B.*.5a`, `B.*.5b`, `late_delivery=no`). That includes a recurring schedule: the schedule `sp_addpublication_snapshot` creates runs every 5 minutes, and an `immediate_sync` publication generates every article at every run (lab: SalesPub generated 2 articles at each of 12 runs in an hour, SalesRef none). `plan` therefore refuses the option when the publication's snapshot agent has a recurring schedule ("the deferral would last until the next scheduled run"). The plan states in its summary that the full generation is deferred to the next run of the agent, and does not plan that run (see "Inputs" for why this state is not pending).

  Measured on 2022 CU27 by `15-snapshot-scope` phase B, under `native` and `concurrent`, with `allow_anonymous` true and false at the start: the sequence behaves as specified, and the cost table holds its entries for that version and those two methods. Under `character`, `concurrent_c` and `database snapshot`, and on a version where the campaign has not run, `plan` refuses the option with "cost of deferred snapshot not measured". The default stays the rule above. My call: an option, not a property of the file, because it chooses a path, not an end state.
- Drop an article: `sp_dropsubscription @article, @subscriber, @destination_db` for each subscription to it, then `sp_droparticle`. `sp_droparticle` needs `@force_invalidate_snapshot = 1` exactly when the publication has `immediate_sync` and its snapshot has been generated (`immediate_sync_ready = 1`): measured refused with 20607 there, accepted without the flag on an `immediate_sync` publication with no snapshot yet and on a publication without `immediate_sync` whose snapshot was delivered (panel, second round; `05-snapshot-flag` `S1.O2` and `S7.O2` against `S2.O2` and `S3.O2`; `06-structural` `C2.*`). The same condition governs `sp_addarticle` and the `sp_change*` flags, and `@force_reinit_subscription` is needed when the operated article's subscription is at status 2 (`05-snapshot-flag`, states `S3`, `S5`, `S6`). The replays on 2019 and 2025 confirm both per version. Cost: new snapshot where the flag is needed. A subscribed article is refused with 14046: the subscriptions to it are dropped first.
- Drop an article and add it back in the same publication: `sp_droparticle` then `sp_addarticle`, both with the flags above; on an `immediate_sync` publication the existing subscriptions are extended to the re-added article automatically and it is delivered by the next snapshot, alone (panel; `06-structural` `C3.*`). The plan never re-adds the subscription alone with `@article = 'all'` after dropping it for one article: the article comes back active with no data delivered (panel).
- Move an article between publications: drop from the source, add to the target, with the rules above (panel: executes).

Filters and views. The synchronization view is what the snapshot reads; the filter procedure is what the log reader uses. The two must always carry the same clause and column list:

- a row filter is created or changed by `sp_articlefilter @filter_name, @filter_clause`, immediately followed by `sp_articleview @view_name, @filter_clause` with the same clause;
- a row filter is dropped by `sp_articlefilter @filter_clause = NULL`, which drops the filter procedure (panel, second round), immediately followed by `sp_articleview @view_name, @filter_clause = NULL`;
- a column filter (`sp_articlecolumn`) is applied before the `sp_articleview` call. `sp_articlecolumn` rebuilds an existing view by itself when the article has a subscription, at status 1 or 2 (`14-filter-view` `F6s`, `F6u`), and not when it has none (`F6`), even with the reinit flag (`F6r`): the rebuild follows the existence of a subscription, not the flag. The first version cited `F6` as confirming the rebuild; it shows the opposite, on an unsubscribed article. The plan re-issues `sp_articleview` with the article's clause after every column change, which costs nothing and does not depend on that behavior;
- `sp_articleview` is never called without the article's clause: called without `@filter_clause`, it rebuilds the view unfiltered and also sets `sysarticles.filter_clause` to NULL, while the filter procedure keeps filtering the changes (verified after the panel: snapshot unfiltered, changes filtered, export showing no filter; `14-filter-view` `F4`);
- `sp_addarticle @filter_clause` is never generated alone (lab row 12).

Measured on the lab: `sp_articlefilter` with a new clause rewrites the procedure and `filter_clause` but leaves the view on the old clause; with NULL it drops the procedure and also leaves the view (panel, verified twice; `14-filter-view` `F2b`, `F2bs`, `F2bu`, `F3`). The flags these calls need follow the general rule: the reinit flag only when the subscription is at status 2 (`14-filter-view` `F*s` against `F*u`). The reader warns when it finds a filter clause without a filter procedure, a filter procedure with a NULL clause, or a view whose definition does not contain the article's clause.

Subscriptions:

- Push subscriptions (`sp_addsubscription`, `sp_addpushsubscription_agent`) run at the publisher, in the publication database, not at the distributor (in the distribution database they fail with 14013, panel); the jobs they create live in `msdb` at the distributor.
- Pull subscriptions: `sp_addsubscription @subscription_type = N'pull'` at the publisher, then `sp_addpullsubscription` and `sp_addpullsubscription_agent` at the subscriber, with `@subscription_type = N'pull'` always passed: left out, `sp_addpullsubscription` creates an anonymous subscription on 2022, out of scope, while the publisher records a named pull (panel); the 2019 source raises 20016 instead. Measured on 2022 as well: without it, the subscriber records an anonymous subscription, the publisher a named pull, and the agent fails with 21084 (`08-pull` `P1.omitted`). Dropping one: `sp_droppullsubscription` at the subscriber, then `sp_dropsubscription` at the publisher, which leaves nothing at either step (`08-pull` `P3.subscriber-first.*`). The other order leaves the pull agent running and logging 21021, "The subscription does not exist", until the subscriber drop (`P3.publisher-first.*`).
- A subscription to a subset of articles (`articles:` in the file) is only possible on a publication without `immediate_sync` and with `native`, `character` or `database snapshot` sync (`database snapshot` accepted a named article, `15-snapshot-scope` `A.non.dbsnap`). On the others, `plan` refuses the file: `sp_addsubscription @article` fails with 14100 on concurrent sync, whether or not `immediate_sync` is set, and with 14122 on `immediate_sync` with native or character sync (panel, second round).
- A whole subscription is dropped by one call, `sp_dropsubscription @article = N'all'` (panel, second round, two readers; `@article = NULL` is refused with 14043).
- A subscription that covers fewer articles than its publication, on a publication where a subset cannot exist, is an intermediate state of the strategies above (an article whose subscription was dropped and which is not yet dropped; an article added and not yet subscribed). The plan completes it with the cheapest step from the observed state: dropping the article, or extending the subscription with `@article = 'all'`, which delivers only the missing article. It never answers it with a drop and re-creation of the subscription.
- Drop and re-add of subscriptions (forced by `independent_agent`, `enabled_for_het_sub`, `allow_push = false`, see below): the subscriptions are re-added with snapshot initialization and the plan announces a reinitialization. For a subscription whose `initialization` is "replication support only", backup or LSN, re-adding it the same way would lose the changes made between the drop and the re-add (panel). Measured: "replication support only" loses them silently (`10-init-modes` `I1.support-only.gap`), and the original backup or LSN replays rows already delivered and stops on 14151 (`I2.backup.gap-original`, `I3.lsn.gap-original`). Two re-creations deliver every gap row: a fresh `COPY_ONLY` backup restored over the subscriber (`I2.backup.gap-fresh`), which replaces the whole subscriber database, its tables and data that are not replicated included, and `initialize from lsn` with the subscriber's `transaction_timestamp` (`I3.lsn.gap-resume`, measured on single-row inserts only). Both need work at the subscriber or an LSN read there; the plan refuses, with the reason and these two ways, and leaves it to the DBA. My call. An LSN given to `initialize from lsn` is checked before the call (its round trip, not beyond the end of the log, not before the backup's LSN): a wrong one was accepted without an error and stopped every subscription of the publisher database on the lab (`lab/README.md`, "Initialization without a snapshot").

Publication properties:

- Property chains: `allow_anonymous` needs `immediate_sync` needs `independent_agent`; `compress_snapshot` needs `alt_snapshot_folder`; `enabled_for_internet` needs `ftp_address`; `replicate_partition_switch` needs `allow_partition_switch`. Enable from the bottom up, disable from the top down (measured).
- `independent_agent` cannot change while the publication has subscriptions (error 20013): the plan drops the subscriptions, sets `immediate_sync = false` first where it is true (21022 otherwise), changes `independent_agent`, and adds the subscriptions back with `@article = 'all'` and their agents (panel: executes). Cost: drop and re-add.
- Properties no flag can change while subscriptions exist (`enabled_for_het_sub`, `allow_push = false` with push subscriptions): the same drop and re-add, or a refusal with the reason when the file asks for something impossible.

Agents and profiles:

- No `sp_add*_agent` procedure takes a profile (panel, from `sys.all_parameters` and the sources in `stored-procedures/`): an agent is created on the default profile of its type, then bound to the file's profile by `distribution.dbo.sp_update_agent_profile @agent_type, @agent_id, @profile_id`. The procedure lives in `msdb` and checks that it runs in the distribution database: called as `msdb.dbo.sp_update_agent_profile` it executes in `msdb` whatever the current database and refuses with 21482, which the second review round took for a refusal of the binding itself; called through the distribution database it succeeds (`07-changes` `PRF.distribution-prefix`; the plain name also works when the current database is `distribution`, `PRF.plain-name.cwd-distribution`). Profiles are created before the agents that use them.

### Order

The order of section 6 of the analysis, extended for creation and corrected by the panel:

1. distributor: create what is missing, skipping what exists (`sp_adddistributor`, run in `master` with `@distributor` (5001 elsewhere, `distributor-defaults` `X.sp_adddistributor.*`), fails with 14099 when a distributor exists, panel; `sp_adddistributiondb` and `sp_adddistpublisher` run from any database), or change it (`sp_changedistributiondb`, `sp_changedistpublisher`);
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
5. on success, starts the snapshot agent of each publication whose snapshot is pending (definition in "Inputs"), then waits until the snapshot is generated and delivered to the subscriptions concerned (agent history: the run's end, then for each subscription the "Delivered snapshot" line that names the run's folder, `16-snapshot-report-sources` `RS.*.distribution_history`), up to a timeout (`-wait`, default 30 minutes; `-wait 0` does not wait). It reports what was delivered; a snapshot not delivered within the timeout is reported as started and unconfirmed, and `apply` exits with a distinct status. My call: "the data at the subscriber is what the file describes" is only claimed for what was confirmed.

On failure, `apply` reports what ran, what failed with the server's message, and what remains. It does not undo. Running `plan` again reads the server as it is and plans from there; the operations already done are no longer in it, the intermediate states of the strategies are completed (see "Subscriptions"), and a snapshot that a subscription awaits but that was never regenerated is seen as pending in the observed facts (definition in "Inputs"), which gives the plan an operation to start it (panel, second round: otherwise the next plan has nothing left to do and the subscription stays without its data). This is why convergence is a requirement.

`apply` does not wrap the operations in one transaction: several procedures create jobs, databases or linked servers, some on other servers, and `sp_addsubscription` refuses to run inside a transaction (error 15002, panel).

The panel met a deadlock (1205) during a sequence of subscription drops and a "only one Log Reader Agent or log-related procedure" message (18752) during `sp_droppublication`. `apply` treats them as failures, stops, and lets the next `plan` resume. The campaign did not reproduce either error in ten create and drop cycles (`13-transient` `T01` to `T10`), so whether a bounded retry is safe is not settled, and the rule stays a stop. My call.

## Snapshot runs and their report

Rudi's request, 2026-11-11: a snapshot that does not block the publisher, and a report of each snapshot that can be exported.

### Blocking

Three things decide how a snapshot blocks writers on the published tables: the publication's `sync_method` (how long), `immediate_sync` (which tables), and the schedule of its snapshot agent (how often). The measurements come from the review of e220523 (five readers, a writer updating one row in a loop during a generation) and from `15-snapshot-scope` phase A, where writers update one row every 50 ms on every table during the run.

- The lock covers only the tables the run generates: every table of the publication under `immediate_sync`, which generates every article (`A.imm.*`), the new table alone without it (`A.non.native`: `m_t3` waited 3141 ms, `m_t1` and `m_t2` 16 ms).
- `native` and `character` lock the generated tables together, not each while it is copied. In the review, a writer on a 100-row table copied in 40 ms waited 4.6 s, as long as the writer on the 1M-row table; in `A.imm.native` and `A.imm.character` the writers of the two tables waited alike and at the same time (`t2_vs_t1=similar`, `overlap_t1_t2=yes`), `character` as `native`. The lock ends with the snapshot history's last line (`t1_ends_at_gen_end=yes`) and covered between a third and two thirds of the history's duration in these runs: 2044 ms of 3990 under `native`, 3002 of 4920 under `character`, 3141 of 5290 for the one table of `A.non.native`, 1235 of 3220 for that of `A.non.character`. The history says "Locking published tables while generating the snapshot", but its times are the times the agent wrote the rows, not the times of the events: its lines come in bursts a few milliseconds apart, and under `database snapshot` the writers were released 600 ms before the Locking line was written (`A.imm.dbsnap`). No step of `apply` and no figure of the report is placed by a history line other than the first and the last, and the last line does not bound the lock under `concurrent_c` (next item).
- `concurrent` and `concurrent_c` lock briefly near the end. Under `concurrent` the writers waited about 100 ms at the end of the run (`A.imm.concurrent`, from +4655 to +4751 ms of a 4757 ms run). Under `concurrent_c` the one measured wait, 207 ms on all three tables together, came after the run's last history line: from +7196 to +7403 ms of a 5303 ms run, about 1.9 s later (`A.imm.concurrent_c`); one row, campaign item 18 measures it again. The review measured 0.1 to 1 s. Under `concurrent` the writer's longest UPDATE took 101 ms, of which 24 ms were lock wait; the rest was not a lock wait (a development run of task 11b saw `WRITELOG`) (`16-snapshot-report-sources` `RS.concurrent.sampling_250ms`). They exist for transactional publications only, and are refused on a snapshot publication with 22547 (`09-snapshot-pub` `SNAP.P12`).
- `database snapshot` and `database snapshot character` read a database snapshot. Writers wait about 200 ms near the start, while the database snapshot is created, and not after: `A.imm.dbsnap` 211 ms, `F.imm_dbsnap_1` to `_3` 109 to 195 ms, `A.non.dbsnap` 321 ms on the new table (the review: under 0.6 s, under 0.2 s on most runs). `database snapshot character` is not measured. They need the Enterprise or Developer edition, which `plan` checks as a precondition. They store `sync_method` 5 and 6. Today the export decodes these as `unknown(5)` and `unknown(6)` (`internal/decode`, `syncMethods`), so plan 2 adds both codes to the code table before the planner compares them.
- An `immediate_sync` publication generates every article at every run of its snapshot agent. The default schedule runs it every 5 minutes, so under `native` the generated tables are blocked for the locked part of each generation every 5 minutes, whatever the plan does (lab: SalesPub, 12 full generations in an hour).

`plan` warns, for a publication of the file of either type, on two things. First, when it uses `native` or `character`: the warning gives the measured cost of moving to `concurrent`, a reinitialization of every subscription plus the snapshot flag when the publication has `immediate_sync` and a ready snapshot (`15-snapshot-scope` `C.native.sync_method`, `D.non_native_pub.change`; `02-matrix` `P22`), and says that a move from `native` or `character` to `database snapshot` is not measured on a transactional publication (only the reverse is, `C.dbsnap.sync_method`, which marks nothing). Second, when it combines `immediate_sync` with a recurring snapshot schedule: the warning gives how often a full generation runs. The omitted value of `sync_method` stays the SQL Server default (`native`), per "Omitted properties". My call: warnings, not changed defaults, because the file is the whole truth and a silent default would contradict the export.

The cost of a `sync_method` change depends on its source and target, not on the property alone. A change from or to `concurrent` or `concurrent_c`, between those two included, needs `@force_reinit_subscription` and marks every subscription for reinitialization (`C.native.sync_method`, `C.concurrent.sync_method`, `C.concurrent_c.sync_method`, `D.non_concurrent.sync_method_probe`, `D.non_native_pub.change`, `D.non_concurrent_pub.change`, `D.*_pub.extend_then_change`; `02-matrix` `P21`, `P22`). A change between `native`, `character` and `database snapshot` marks nothing and needs at most the snapshot flag, when the publication has `immediate_sync` and a ready snapshot (`C.character.sync_method`, `C.dbsnap.sync_method`, `D.non_native.sync_method_probe`, `D.imm_native.sync_method_probe`). The measured pairs within that group are `native` to `character`, `character` to `native` and `database snapshot` to `native`; on a snapshot publication, `native` to `character` and to `database snapshot` (`09-snapshot-pub` `SNAP.P13`, `SNAP.P14`, `SNAPI.P13`, `SNAPI.P14`). Any other pair is refused as not measured, campaign item 18. The first version of this section called every `sync_method` change a reinitialization; the rows above contradict it.

### The report

Every snapshot that `apply` starts (step 5, and the "generate and wait" operation of `-defer-full-snapshot`) produces a report, and so does every snapshot that `sqlrepl snapshot -publication <name>` starts. That command starts the snapshot agent of one publication, waits like `apply` (`-wait`), and writes the report. It changes no configuration, so it needs no plan.

The report is written only once the run has ended or the wait has timed out, so it never shows a figure that can still change. A timed-out run gives a report marked incomplete, with what was collected. `-wait 0` writes no report, and `sqlrepl snapshot` refuses `-wait 0`.

The report is one self-contained HTML file (no external script, style or font, so it can be mailed or attached), next to a JSON file with the same data, which the GUI reads later. The path is set with `-report <path>`; by default it is `snapshot-<publication>-<UTC timestamp>.html` in the current directory.

Starting the agent is checked through the return code. When the job is already running, `sp_startpublication_snapshot` refuses, but raises no error that TRY...CATCH sees, and `@@ERROR` stays 0: only the return code is 1 (review of e220523; `16-snapshot-report-sources` `RS.*.start_running`, under the three methods measured). The only message is an informational "HResult 0x5606, Level 16, State 1" line followed by the Agent's "Request to run job ... refused because the job is already running", not a `Msg` line, so a client that only watches for errors sees nothing. `sqlrepl` therefore checks that the agent's job is not running before it takes its mark. It refuses with "snapshot agent already running" when it is, and treats a non-zero return code as a failed start. Without these checks, the report would describe a run `sqlrepl` did not start.

What the report holds, and where each value comes from:

- the run: publication, `sync_method`, the edition, and the start and end of the generation and of each subscription's delivery. These come from the snapshot and distribution agent history after a mark taken before the start. For a publication without an independent agent, the delivery rows belong to the shared agent (`publication = 'ALL'`); they are attributed to the publication through the run folder named in the "Delivered snapshot from the '...' sub-folder" line, which names it for a shared agent too (`RS.native.distribution_history`, `agent=shared`). Only the first and the last history lines place the generation in time (see "Blocking").
- per article: the rows bulk copied and the time it took at each subscriber. The distribution history writes one "Bulk copied data into table" line per bcp partition, naming the destination table: the report sums the lines and maps each destination table back to its article through `dest_table`. The sums equal the source row counts (`RS.*.distribution_history`, `bulk_sums_match=yes`). The snapshot history has per-article bulk copy and schema lines under every method measured, `concurrent` included (`RS.*.snapshot_history`, `per_article_lines=yes`; `15-snapshot-scope` `A.imm.concurrent`); the review of e220523 had seen none under `concurrent`, and the first version of this section followed it. Their times are write times, so a per-article generation time read from them is approximate, and the report says so.
- the files of the run, with their size, and the total for the run's folder, read on the distributor with `sys.dm_os_enumerate_filesystem`. This works for the default folder, for a sysadmin and for a login with only `public` at the server and `SELECT` in the distribution database, which see the same files and bytes as `find` (`RS.*.filesystem_sa`, `RS.*.filesystem_low`). An alternate or UNC folder the distributor cannot list is reported as not readable, never guessed.
- blocking: the sessions that waited on a lock held by the snapshot agent, and the sessions the agent waited on, with the object, the wait type and the longest wait. They are sampled on the publisher from `sys.dm_exec_requests` (with `blocking_session_id`) and `sys.dm_os_waiting_tasks`, from the mark until the later of two moments: the end of the run's last delivery, and 5 s after the snapshot history's last line. The margin, not a test of when the lock is gone, is the choice: the latest lock measured ended 2.1 s after the last line (`15-snapshot-scope` `A.imm.concurrent_c`, +7403 ms in a 5303 ms run), and 5 s covers more than twice that; a sampler that waited for the lock to go would have to know which session holds it, which the `program_name` rules below cannot always tell. Item 18 checks the margin.
  - Which sessions belong to the agent (`RS.*.program_names`, sampled every 250 ms, so a lower bound). The snapshot agent's sessions carry the snapshot job's name, which equals `MSsnapshot_agents.name`, `SQLAgent - TSQL JobStep (Job <job id> : Step n)`, "Snapshot Agent Distributor Connection for publication '<server>:<database>:<publication>'", "Snapshot Agent History Connection for publication ...", "Snapshot BCP thread #n for publication <name>", and under `database snapshot` "Database snapshot creation connection for publication <name>". "Snapshot Agent Smo Connection" names no publication and cannot be attributed. An independent distribution agent's sessions are named `<instance>_<publisher_db>_<publication>`; a shared one's `<instance>_<publisher_db>` (`repllab_Sales`), which cannot be tied to a publication by `program_name`. The writer's blocker was the session named after the snapshot job under `native` and `database snapshot` (`writer_blocked_by=[<snapshot_job>]`); under `concurrent` no blocker was seen, the lock being shorter than the sampling interval. The report attributes a session to the run by the job name or the publication name it carries, and lists the others as unattributed.
  - Sampling misses waits. Compared with the writer's own lock wait: at 1 s, the 2462 ms wait under `native` read as 1554 ms and the 289 ms wait under `database snapshot` was missed; at 250 ms they read as 2376 ms and 36 ms (`RS.native.sampling_1s`, `RS.native.sampling_250ms`, `RS.dbsnap.sampling_1s`, `RS.dbsnap.sampling_250ms`). The review had seen the same at 1 s (a 1.6 s wait missed, a 4.6 s wait read as 3.8 s). The report samples every 250 ms, states the interval, says that the longest wait it shows is a lower bound, and that a wait shorter than the interval may not be seen at all.
  - Permission. The sampling needs `VIEW SERVER PERFORMANCE STATE` on 2022 (`VIEW SERVER STATE` before 2022): without it, `sys.dm_os_waiting_tasks` fails with error 300, while `sys.dm_exec_requests` raises no error and returns the caller's own session only (`RS.m_low.waiting_tasks`, `RS.m_low.exec_requests`), so the check reads the permission itself, not an error. `sqlrepl snapshot` and `plan` check it before the start. Without it, the report says the blocking was not collected, and the snapshot still runs.
  - No server option is changed. The report does not use the `blocked_process_report` event, which needs the server option `blocked process threshold` and an event session. `sqlrepl` never changes a server option or creates a server object for a report. My call.
- agent errors and retries during the run (agent history, `MSrepl_errors` after the mark).

Apart from the snapshot itself, the report only reads from the servers. Its sources are measured under `native`, `concurrent` and `database snapshot` by `16-snapshot-report-sources` (campaign item 13); `character` and `concurrent_c` are taken to read like `native` and `concurrent`, which their history lines in `15-snapshot-scope` support (`A.imm.character`, `A.imm.concurrent_c`: per-article lines present).

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
- the observed runtime facts the planner takes as input ("Inputs"), the state of each distribution agent included;
- the definition of each synchronization view, enough to check it against the clause and the columns.

## Measurement campaign

The first block of the implementation plan, before the planner (Rudi's decision). Each item became a script under `lab/campaign/`, written so that it runs unchanged on every supported version. The campaign runs on 2022 first, and the engine is built on those results; the scripts are then replayed on 2019 and 2025, and the support claim for those versions holds once they have run and their differences are in the cost table (Rudi's decision). Results are recorded per version in `lab/README.md` and in the cost table:

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
12. the scope of a snapshot generation after an article is added, for each `sync_method` (`native`, `character`, `concurrent`, `concurrent_c`, `database snapshot`) with and without `immediate_sync`, on snapshot agents that never run on a schedule: which tables the agent generates files for (files in the run folder, snapshot history), which existing tables it locks and for how long (a timed writer on each table, the new one and the existing ones), and the duration. Then the `-defer-full-snapshot` sequence, with `allow_anonymous` both true and false at the start. For each step: the flags it needs, `immediate_sync_ready` and every subscription status, the tables generated before the restore, and what a subscriber added after the restore receives. The race of restoring before the generation ends. Whether each invalidating operation leaves a subscription status that awaits a generation, which the definition of a pending snapshot in "Inputs" relies on. Extending a subscription marked for reinitialization in the same plan;
13. the sources of the snapshot report, under `native`, `concurrent` and `database snapshot`. What the snapshot and distribution histories return, including the delivery rows of a shared agent. What `sys.dm_os_enumerate_filesystem` returns on the run folder, under a sysadmin and under a login with only the permissions `sqlrepl` documents. The `program_name` of every session the snapshot agent opens. Whether sampling `sys.dm_exec_requests` and `sys.dm_os_waiting_tasks` sees the blocking a timed writer measures, at one second and at a shorter interval. The return code and messages of `sp_startpublication_snapshot` when the job is already running. The error a login without `VIEW SERVER PERFORMANCE STATE` gets.

Status on 2022 CU27 (2026-11-10 and 2026-11-11): every item has run, through `lab/campaign.sh`, and each script has its section in `lab/README.md`. Item 1 is `05-snapshot-flag`; 2 and 4 `06-structural`; 3 `03-add-article` and `06-structural` `C4`; 5 `07-changes`; 6 `08-pull`; 7 `09-snapshot-pub`; 8 `10-init-modes`; 9 `11-defaults`, `12-contexts` and `distributor-defaults`; 10 `13-transient`; 11 `04-filter-clause` and `14-filter-view`; 12 `15-snapshot-scope`; 13 `16-snapshot-report-sources`. What they left open, and the items that follow from it:

14. a snapshot generated and not delivered: the windowed test of "Inputs" (snapshot commands between an article's `subscription_seqno` and `ss_cplt_seqno` beyond the distribution agent's last history `xact_seqno`). The true positive, with the agent stopped after a generation that a subscription awaits, with and without `immediate_sync`; the negative control the test must pass, an `immediate_sync` publication whose subscription is fully delivered, agent stopped, one more run of the snapshot agent, where the test must say nothing is awaited; and the lag between new snapshot commands and the agent's next history write;
15. a named extension on a `native` or `character` publication, or an `sp_addarticle` on an `immediate_sync` publication, whose every subscription row is marked by a `sync_method` change from or to the concurrent family (see "Strategies");
16. a restore of `immediate_sync` committed during the generation, rather than before the agent reads the publication;
17. the intermittent delivery failure of a just-added article under `database snapshot` ("Could not find stored procedure 'dbo.sp_MSupd_dbom_t3'", round 1 `A.imm.dbsnap`), not reproduced by `F.*`;
18. the lock timing under `concurrent_c` (one row, after the history's last line) and the report's sampling margin; `sync_method` from `native` or `character` to `database snapshot` on a transactional publication, any change involving `database snapshot character`, and the `-defer-full-snapshot` sequence under `character`, `concurrent_c` and `database snapshot`;
19. smaller gaps: a subscription at status 1 with a ready snapshot reached through `sp_reinitsubscription` (`05-snapshot-flag`), the default of `sp_addsubscription @subscriber_type` (`11-defaults`), and 1205 or 18752 during drops, not seen in ten cycles (`13-transient`).

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
