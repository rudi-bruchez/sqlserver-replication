# SQL Server replication oddities

This document collects the behaviors of the SQL Server transactional replication procedures and system tables that surprised us while building `sqlrepl`: what a DBA would expect, what the server does instead, and where Microsoft Learn says something the lab measured otherwise. It is a reference to keep and to write from, not a design document: the consequences for `sqlrepl` are in the design and the plans.

## How to read it

What was measured. Almost everything comes from the lab of `lab/README.md`: one SQL Server 2022 Developer container on Linux, CU27 (16.0.4305.5), which is at once distributor, publisher and push subscriber, with SQL Agent enabled. An entry is about 2022 CU27 unless it says otherwise. On SQL Server 2019 CU32 (15.0.4500.2) and 2025 CU10 (17.0.5035.5) only the parameter listing `17-parameters` has run, plus a few runs by review seats on containers of their own, named as such. The lab is a default instance on Linux: nothing here is measured on a named instance, on Windows, or with a remote distributor.

Each entry gives what one would expect, what the server does, and where it was seen. The citations are:

- `<script> <case>`: a row of `lab/results/2022/<script>.txt`, for example `05-snapshot-flag S7.O1`; the scripts are in `lab/campaign/`, and the README section of each script describes the cases. `lab/results/2019/` and `lab/results/2025/` hold `17-parameters` only.
- `lab row <n>`: the numbered tables of `lab/README.md` (rows 1 to 12).
- `O<n>`: an observation of `lab/README.md`, "Observed outside the campaign", run once by hand by a review seat or the controller.
- `<file>:<line>`: a comment in the code that records a trap, usually in `internal/reader/`.
- The ledgers and reports of the plan executions, git-ignored session state under `.superpowers/sdd/`: `ledger 1`, `ledger 2`, `ledger 3` are the `progress.md` of plans 1, 2 and 3; `p1 task-N-report`, `p2 task-N-report`, `p2 final-fix-report` are the reports beside them; `p2 triage` and `p3 triage` the `panel-triage.md` files.
- The review panels on plans 2 and 3, whose seats ran scenarios on the lab: `panel 2 <seat>` is `docs/analysis/panel-reports/plan2/review-<seat>-b56f9b8e62c4.md`, `panel 3 <seat>` is `docs/analysis/panel-reports/plan3/review-<seat>-b32d486df297.md`, copied into the repository from the session where they were written. Seats: Claude (Opus or Fable), codex directive, codex neutral, GLM, Mistral.
- `plan3-fold-review mN`: the scripts `m1.sql` to `m5.sql` and the outputs `m3.out` to `m5.out` in `docs/analysis/panel-reports/plan3-fold-review/`, run on the lab (2022 CU27) while plan 3 was folded after its panel. `m1` and `m2` have no output file in the folder.
- `[R]`: the 2019 sources of the system procedures in `stored-procedures/`.

Every entry says how it is known. "Measured" means somebody ran it and read the result. "By reading" means it was concluded from a procedure definition, the 2019 sources, or field experience, and was not run; those entries are marked as such. One entry (the error stack of `MSrepl_errors`) was read on the lab, read-only, while this document was written.

Refused calls are written with their error number, `Msg <n>` or simply `(n)`. The table at the end lists every number met.

## Publications

### Default schema option of a table article

- Expected: `0x30F3`, the default Learn gives on the `sp_addarticle` page.
- Observed: `0x30073`. The primary key bit `0x80` is not set: the primary key travels as the clustered index. A table article of a snapshot publication gets `0x30071`. A schema-only article gets `0x1`.
- Source: measured, `01-articles A2`, `11-defaults D.sp_addarticle.table.native.@schema_option`; the snapshot and schema-only values from the `11-defaults` rows quoted in the design, "Omitted properties".

### Article status bits set by schema option 0x8

- Expected: `sysarticles.status` holds the documented bits only (1 active, 8 column names in INSERT, 16 parameterized commands).
- Observed: a `schema_option` with `0x8` (timestamp as timestamp) sets `status` bit `0x8` and also `0x20`, which is not documented.
- Source: measured, `01-articles A3`; `internal/decode/decode.go:226`.

### Undocumented codes of syspublications

- Expected: Learn's code tables are complete.
- Observed: `sync_method` stores 5 for `database snapshot` and 6 for `database snapshot character`, not on Learn (and 2 is not documented either). `options` has `0x20` for `allow_partition_switch` and `0x40` for `replicate_partition_switch`, measured, and `0x80` for `allow_drop`, read in the source (`@OPT_ALLOW_DROP`).
- Source: measured in rolled-back transactions, plan 2 "Rulings made in this plan", panel 2 Mistral; `0x80` by reading, `[R] sp_MScheck_dropobject.sql:25-29`; `internal/decode/decode.go:189`, `:245`, `:249`.

### Partition switch defaults

- Expected: `replicate_partition_switch` defaults to false, independently of `allow_partition_switch`.
- Observed: `sp_addpublication @allow_partition_switch = N'true'` alone stores `options` 96 (`0x60`): the omitted `replicate_partition_switch` takes the value of `allow_partition_switch`. Passing `@replicate_partition_switch = N'false'` gives 32. `replicate_partition_switch` true without `allow_partition_switch` is refused, with 21678 at creation and with 21866 by `sp_changepublication`.
- Source: measured, panel 2 Claude (table of four calls), panel 2 Mistral, controller (p2 triage item I); `02-matrix` for 21866 (analysis section 5).

### Property chains of a publication

- Expected: properties change independently.
- Observed: `allow_anonymous` needs `immediate_sync` (20011), which needs `independent_agent` (21022); `sp_addpublication @immediate_sync = 'true'` alone is refused with 21022 and does not fill `independent_agent`. `independent_agent` cannot change while subscriptions exist, in either direction (20013), so it cannot be turned off while `immediate_sync` is on (21022) and cannot be turned on once subscribed. `compress_snapshot` needs `alt_snapshot_folder` (21157), `enabled_for_internet` needs `ftp_address` (21158), `allow_subscription_copy` needs `immediate_sync` (21210), `enabled_for_het_sub` is refused while subscriptions exist (20640), `allow_push = false` while push subscriptions exist (20012, whose message contains `(null)`).
- Also observed: `sp_changepublication @property = N'allow_pull', @value = N'false'` on a publication with subscriptions is refused with 20013 (plan 3 task 8 review, measured, 2026-11-12).
- Also observed: `independent_agent` set to false while subscriptions exist returns 20013 in all four flag cells (plan 3 task 7 review, measured); the lab rows of the matrix cover only the change to true (`02-matrix P26`, `09-snapshot-pub SNAP.P16`, 20013 in all four cells), the change to false on an `immediate_sync` publication returning 21022 (`02-matrix P25`, `09-snapshot-pub SNAPI.P16`). `enabled_for_het_sub` true returns 20640 in all four cells while subscriptions exist (`02-matrix P37`, `09-snapshot-pub SNAP.P24`, `SNAPI.P24`).
- Source: measured, `02-matrix` (analysis section 5, table "Publication properties"), the panel for `sp_addpublication` (design, "Omitted properties").

### Heterogeneous subscribers and autogenerated procedures

- Expected: `enabled_for_het_sub` can be set on any publication without subscriptions.
- Observed: it also needs `autogen_sync_procs` false.
- Source: measured by the reviewer of plan 2 Task 6, ledger 2 line 42. The reviewer's report is not kept; the ledger line is the only record.
- Also observed: a change of `enabled_for_het_sub` rewrites every article of the publication, and the output shows "Article update successful" once per article. Source: plan 3 task 7 review, measured.

### A snapshot publication made immediate_sync

- Expected: a snapshot publication can be given `immediate_sync` later.
- Observed: once it has a subscription, `independent_agent` is refused with 20013, so it cannot become `immediate_sync`.
- Source: measured, p1 task-8-report (concern 4), `09-snapshot-pub`.

### Publication names differing only by case

- Expected: in a case-sensitive publication database, `P` and `p` are two publications.
- Observed: they collide in `distribution.dbo.MSpublications`, and `sp_droppublication 'all'` then fails and leaves its transaction open.
- Source: measured in the re-review of plan 2's final fixes, ledger 2 line 90; plan 3 rule R7.

### The log reader of a database dropped with its last publication

- Expected: the log reader agent belongs to the database and stays until the database is unpublished.
- Observed: dropping the last publication of a database also drops its log reader agent, its job and its `MSpublisher_databases` row. Whether a later `sp_addpublication` recreates a log reader implicitly is not measured after such a drop. On a database published for the first time, `sp_addpublication` creates and starts one by itself: it prints "Job 'REPLLAB-rv_fxk3q1_p-14' started successfully" and "The logreader agent job has been implicitly created and will run under the SQL Server Agent Service Account", and `MSlogreader_agents` then has one row for the database. As with the distribution agent job, it runs under the Agent service account until changed.
- Source: measured, `13-transient T02`, `T04`, `T06`, `T08`, `T10` (`logreader_after_drop=dropped`); `plan3-fold-review m3` (the warning and `logreader|1`), `m5` (the same warning).

### A database published for merge only

- Expected: `sys.databases.is_published` is 1 for a database with publications.
- Observed: a database published for merge only has `is_published = 0`; only `is_merge_published` shows it (the reader reads both, `internal/reader/queries.go:27`).
- Source: plan 2 "Rulings made in this plan" (the empty configuration ruling), from the design's reading of `sys.databases`; not run as a case of its own.

### Commands, initialization from backup and concurrent sync on a snapshot publication

- Expected: a snapshot publication behaves like a transactional one for the properties they share.
- Observed: changing `ins_cmd`, `upd_cmd` or `del_cmd` needs a reinitialization on a snapshot publication, and both flags when the snapshot is ready, while the same changes are online on a transactional twin. `allow_initialize_from_backup` is refused with 18787. `concurrent` sync is refused with 22547, while `database snapshot` and `database snapshot character` are accepted.
- Source: measured, `09-snapshot-pub SNAP.A06` to `A09`, `SNAPI.A06` to `A09`, `TWIN.A01` to `A04`, `SNAP.P06`, `SNAP.P12`; panel 3 GLM (both database snapshot methods accepted at creation).

### Commands stored schema-qualified

- Expected: an unqualified command procedure is stored as given, or qualified with the schema of the source table.
- Observed: `sp_addarticle` stores the generated procedures as `CALL [dbo].[sp_MSins_dboCustomer]` on 2022, and an unqualified name given in `@ins_cmd` with `[dbo]`, even for a source table in another schema (`CALL m_ins` becomes `CALL [dbo].[m_ins]` for a table of schema `m_s`). `sp_changearticle` keeps an unqualified name unqualified (`CALL [sp_MSins_dboOrders]`). The same name given to the two procedures is therefore stored two ways.
- Source: measured, lab README "Articles and the first measurements"; `11-defaults D.sp_addarticle.table.non-dbo-schema.*`; the panel for `sp_changearticle`, on 2022 and 2025 (design, "Names"; analysis section 5).

### Command procedures of concurrent_c and long names

- Expected: the generated command procedures of two tables never collide, and their names always name the table.
- Observed: under `concurrent_c` the command procedures are named without the source schema, so two tables of the same name in two schemas collide. A generated command name is truncated from 110 characters on, with a 10-digit suffix, so a name past 109 characters cannot be predicted by the caller.
- Source: measured, plan 3 task 5 review, measured and plan 3 task 6, where the ledger says the generated name "is not predictable past 109 characters, measured". The review reports are not in the repository, and the ledger lines do not show the output of the collision case.

### Destination owner of an article

- Expected: an omitted `@destination_owner` is `dbo`, or the source schema, whatever the sync method.
- Observed: it depends on the sync method. Under `native`, `concurrent`, `database snapshot` and `database snapshot character` it is the source schema (`m_s` for a source in schema `m_s`); under `character` and `concurrent_c` it is NULL, for table, view, procedure and function articles alike, on transactional and snapshot publications.
- Source: measured, `O16` (GLM, the fix review, the controller); `11-defaults D.sp_addarticle.*.@destination_owner`, and the rows `D.sp_addarticle.*.nondbo.*` (commit `3541324`), which cover all six sync methods on a source in `m_s`, including `dbsnap_c` (`database snapshot character`, `m_s`).

### Schema-only articles and the active bit

- Expected: the active bit `0x1` of the article status concerns table articles; schema-only articles have no snapshot data.
- Observed: a view or procedure article is 16 after `sp_addarticle`, 17 after the generation and 16 after `sp_reinitsubscription`, exactly like a table article.
- Source: measured by two reviewers of plan 2 Task 11, `internal/reader/queries.go:138-141`, p2 task-11 fix brief; lab test `TestReadLabFacts`.

### The active bit after sp_addarticle on an immediate_sync publication

- Expected: a new article is inactive until a snapshot generates it.
- Observed: on an `immediate_sync` publication, `sp_addarticle` sets the active bit at once. Only the subscription status (1) shows that a snapshot is awaited.
- Source: measured by the plan 2 Task 11 reviewer (Fable), ledger 2 lines 66 and 71; plan 3 rule R12.

## Filters, views and columns

### The article type and user-named filters and views

- Expected: `sysarticles.type` 3, 5 or 7 (manual filter, manual view) tells an article whose filter procedure or synchronization view the user named.
- Observed: `sp_articlefilter` and `sp_articleview` with names keep type 1. A filter procedure is always named by the user, since `sp_articlefilter` without `@filter_name` is refused (14043). A generated view is named `syncobj_0x<hex>`, and `sp_articleview` without `@view_name` generates one.
- Source: measured, `01-articles A5`, `A7`; `internal/reader/publisher.go:226-231`; panel 3 Opus for `sp_articleview` without `@view_name`.

### A filter clause given to sp_addarticle

- Expected: `sp_addarticle @filter_clause` filters the article.
- Observed: the clause is stored and no filter procedure is created. The snapshot is filtered, the changes are not: a row inserted later that fails the clause reaches the subscriber.
- Source: measured, `01-articles A4`, lab row 12, `04-filter-clause F1`; `internal/reader/publisher.go:246-247`.

### sp_addarticle with @filter

- Expected: `sp_addarticle @filter` names the filter procedure the article will use.
- Observed: the procedure must exist already, and `sp_articlefilter` is what creates it, so the call is refused with 14027, followed by Msg 20026 from `sys.sp_MSreinit_article` inside the refused call.
- Source: measured, panel 3 GLM, verified item 1.

### sp_addarticle with @vertical_partition

- Expected: `@vertical_partition = N'true'` starts a column filter from all the columns, to be trimmed with `sp_articlecolumn`.
- Observed: it publishes only the primary key column; later `sp_articlecolumn @operation = 'drop'` calls leave the key alone. Without it, the article starts with every column and the drops work as expected.
- Source: measured, panel 3 GLM, verified item 2.

### sp_articlefilter with a new clause

- Expected: changing the clause changes what the article filters, snapshot included.
- Observed: it rewrites the filter procedure and `sysarticles.filter_clause` and leaves the synchronization view on the old clause, in every subscription state. With a NULL clause it drops the procedure and also leaves the view. The snapshot then reads the old view while the log reader applies the new filter, until `sp_articleview` is called again.
- Source: measured, `14-filter-view F2b`, `F2bs`, `F2bu`, `F3`.

### sp_articleview without a clause

- Expected: `sp_articleview` without `@filter_clause` rebuilds the view and leaves the article's filter alone.
- Observed: it rebuilds the view unfiltered and sets `sysarticles.filter_clause` to NULL, while the filter procedure keeps filtering the changes: the snapshot is unfiltered, the changes are filtered, and the configuration shows no filter. On an article without a filter procedure, though, the same call is the one that builds the view of a column filter: after `sp_articlecolumn` the article has no view of its own (its `sync_objid` names the table) until `sp_articleview` is called.
- Source: measured, `14-filter-view F4`; panel 3 GLM, verified item 6.

### sp_articlecolumn and an existing view

- Expected: `sp_articlecolumn` either always or never rebuilds the article's view.
- Observed: it rebuilds an existing view when the article has a subscription, at status 1 or 2, and not when it has none, even with `@force_reinit_subscription = 1`. A drop changes neither `type` nor `status`.
- Source: measured, `14-filter-view F6`, `F6r`, `F6s`, `F6u`; `01-articles A6`.

### The text sp_articleview writes

- Expected: a generated view text one can compare with the article's clause by simple means.
- Observed: the view is one line, `create view [s].[v]as select [c1],[c2]  from  [s].[t]  where HAS_PERMS_BY_NAME('[s].[t]', 'OBJECT', 'SELECT')= 1  and (<clause>)`, with no space before `as`, double spaces around `from` and `and`, and no `and (...)` when the article has no clause. The clause is kept verbatim, line breaks included. Because the guard itself ends in `= 1`, a parser that takes "the text after the last `= 1`" breaks on any clause containing `= 1` (`flag = 1`, `id = 10`).
- Source: measured, `internal/reader/syncview.go:32-38`; panel 2 Claude, codex directive, codex neutral, GLM and Mistral, each verified item on `checkSyncView`.

### A filter procedure of another article

- Expected: `sp_changearticle @property = 'filter'` with another filter procedure is refused or accepted.
- Observed: with the filter procedure of another publication's article, the connection ends with an engine assertion, Msg 3624, severity 20, in `sp_MSsetfilterparent`, eight times while `09-snapshot-pub` was written; `CHECKDB` was clean afterwards. A plain procedure that is not a replication filter is refused with 14049. A candidate engine bug, not filed.
- Source: measured, `09-snapshot-pub SNAP.A22`, `SNAPI.A22` (which therefore measure the same value only); analysis section 5; p1 task-8-report finding 1; `lab/campaign/09-snapshot-pub.sh:189-192`.

### Filter procedure names stored with dbo

- Expected: a filter procedure named without a schema is stored as given.
- Observed: `sp_articlefilter` accepts `[dbo].[x]` and `dbo.x` and stores the schema `dbo`.
- Source: measured, panel 3 Opus, "Concluded by reading" item 2 (the measurement is quoted inside it).

### The schema of the procedure sp_articlefilter creates

- Expected: the filter procedure goes to the schema of the article's source table.
- Observed: `sp_articlefilter` accepts a schema-qualified `@filter_name` (`N'[s].[f]'`) and creates the procedure in that schema. Unqualified, it goes to the caller's default schema (`dbo` for `sa`), even when the article's source table is in another schema.
- Source: measured, plan 3 task 8 review (2026-11-12).

### The schema of the view sp_articleview creates

- Expected: `sp_articleview` honors the schema of `@view_name`, as `sp_articlefilter` does for its procedure.
- Observed: it ignores it: `@view_name = N'[s].[v]'` returned 0 and created `dbo.v`.
- Source: measured, plan 3 task 8 review (2026-11-12).

### sync_object with an unqualified view name

- Expected: `sp_changearticle @property = N'sync_object'` finds a view by its name.
- Observed: with the unqualified name of a view in a schema other than `dbo`, it fails with 15001 ("Object ... does not exist") and leaves `@@TRANCOUNT` at 1. The qualified name `N'[s].[v]'` is accepted.
- Source: measured, plan 3 task 8 review (2026-11-12).

### Identity range management

- Expected: `@identityrangemanagementoption` concerns updatable subscriptions only; schema option `0x04` (identity as identity) is an independent bit.
- Observed: `manual` serves a plain transactional publication: it marks the table's identity column `NOT FOR REPLICATION` and adds `0x04` to the schema option (`0x30077` against `0x30073`). `0x04` alone, with the option NULL, is refused with 21830. `auto` is refused without updating subscribers (21231), and with them without ranges (21193). `sp_helparticle` does not read the article: it derives the option from the table, `auto` when `MSpub_identity_range` has a row, `manual` when the identity column is `NOT FOR REPLICATION`, whatever bit `0x04` says, `none` otherwise. Removing `0x04` with `sp_changearticle` still reads `manual`, and `sys.sp_identitycolumnforreplication` on a `none` article makes it read `manual`. The definition of `sp_MSrepl_helparticle` is not readable (`OBJECT_DEFINITION` NULL, no 2019 source), so the derivation comes from the measurement alone.
- Source: measured, p2 task-12-fix-1-report (three rounds, tables of results); plan 3 rule R14.
- Learn: says `manual` is for transactional replication without updating subscribers, which is right; plan 2's first rule had it wrong (p2 task-12 fix brief).

## Snapshot flags and subscription states

### When the snapshot flag is asked

- Expected: `@force_invalidate_snapshot` is asked whenever a change invalidates an existing snapshot.
- Observed: it is asked exactly when `immediate_sync_ready = 1`, and only an `immediate_sync` publication ever asks it. An `immediate_sync` publication whose snapshot was never generated, or was invalidated, never asks it, whatever snapshot files are on disk. On a publication without `immediate_sync`, a change that only affects the snapshot needs no flag.
- Source: measured, `05-snapshot-flag` states `S1`, `S2`, `S5`, `S6`, `S7`; `02-matrix` (only `SalesPub` raised 20607); `06-structural C2.*` for `sp_droparticle`.

### When the reinitialization flag is asked

- Expected: `@force_reinit_subscription` depends on the change.
- Observed: it depends on the subscription status of the operated article: asked when that article's subscription is at status 2, not at status 1. For `sync_method`, which concerns every article, when any article is at status 2. The same change on a publication whose rows all await a snapshot needs no flag.
- Source: measured, `05-snapshot-flag S3.O3`, `S5.O3`, `S4`, `S6.O3`, `S6.O6`, `S6.O7` to `S6.O9`; `14-filter-view F*s` against `F*u`; `O9`.

### Flags on a change to the same value

- Expected: setting a property to the value it already has is a no-op that needs no flag.
- Observed: the server asks the flags anyway.
- Source: measured, `09-snapshot-pub SNAP.A22` f01, `SNAPI.A22` f11.

### An unneeded flag

- Expected: passing a flag the change does not need is refused or has an effect.
- Observed: it is accepted.
- Source: measured, `05-snapshot-flag S2.O1` f10.

### Which error shows first

- Expected: a change no flag can make is refused with the reason, whatever flags are passed.
- Observed: the flag errors come first. `sync_method = concurrent` on a snapshot publication returns 20608 without the reinitialization flag, and the real refusal, 22547, only when the flag is passed; with a ready snapshot, 20607 first.
- Source: measured, `09-snapshot-pub SNAP.P12` (`f00=20608,f10=20608,f01=22547,f11=22547`), `SNAPI.P12`.

### A subscription added to a ready immediate_sync publication

- Expected: a new subscription is at status 1 until its snapshot is delivered.
- Observed: `sp_addsubscription` on an `immediate_sync` publication whose snapshot is ready sets the subscription to status 2 at once, before anything is delivered, with its agent stopped and the subscriber table absent, or with the subscriber database offline. It then asks both flags like a delivered subscription.
- Source: measured, `05-snapshot-flag S7`; `O6` (codex directive, codex neutral).

### What sets status 2 and the active bit

- Expected: the delivery of the snapshot.
- Observed: the generation. With the distribution agent stopped, a run sets the subscription to status 2 and the article's active bit while nothing reaches the subscriber; the delivery comes when the agent runs. On a `database snapshot` publication whose delivery failed, the subscription still ended at status 2. A generated, undelivered snapshot therefore reads as delivered in `syssubscriptions` and `sysarticles`.
- Source: measured, `15-snapshot-scope E.extended`, `E.generated_undelivered`, `E.delivered`; `O1` (Mistral, `character`); round 1 `A.imm.dbsnap` (`git show 8db6060:lab/results/2022/15-snapshot-scope.txt`).

### A replication support only subscription

- Expected: status 1 until its agent runs.
- Observed: every row is at status 2, `sync_type` 2, at once, on a publication without `immediate_sync`. On an `immediate_sync` publication whose snapshot has not run, the rows are the same (status 2, `sync_type` 2) beside a push subscription at status 1.
- Source: measured, panel 3 Fable, verified item 4; `plan3-fold-review m3` (`rows_initial`).

### sp_addarticle with a replication support only subscription

- Expected: `sp_addarticle` on an `immediate_sync` publication subscribes the new article for every subscription, and the next snapshot delivers it.
- Observed: the new article gets a row for the replication support only subscription at status 2, `sync_type` 2, like the others, and for the push subscription a row at status 1, `sync_type` 1. A replication support only subscriber receives no snapshot, so the new article is never sent to it and its table must already exist there. The output shows only the `syssubscriptions` rows; it does not show a subscriber table, so "never sent" follows from the `sync_type` and from what the entry on that subscription type measured, not from a delivery test.
- Source: measured, `plan3-fold-review m3` (`rows_after_add_t3`).

### sp_reinitsubscription after an article was dropped from a subscription

- Expected: `sp_reinitsubscription @article = N'all'` re-marks every article of the publication and so brings back an article dropped from the subscription.
- Observed: with a subscription to `t1` and `t2` (push, `@article = N'all'`), `sp_dropsubscription @article = N't2'` left the rows of `t1` only, and `sp_reinitsubscription @article = N'all'` raised no error and left the rows unchanged: `t1` alone, still at status 1. `t2` came back only later, with the next `sp_addarticle` (`t3`) on that `immediate_sync` publication, which re-subscribed the missing `t2` together with the new `t3`: the subscription then had `t1`, `t2` and `t3`, all at status 1, `sync_type` 1 (no snapshot had run on that publication). To complete a subscription by hand, `sp_addsubscription @article = N'all'` is the measured way (entry above).
- Source: measured, `plan3-fold-review m3` (`rows_after_drop_t2`, `rows_after_reinit`, `rows_after_add_t3`).

### Operations that drop a ready snapshot without asking a flag

- Expected: an operation that invalidates the snapshot asks `@force_invalidate_snapshot`.
- Observed: `allow_anonymous = false` and `immediate_sync = false` are accepted with no flag and drop a ready snapshot (`immediate_sync_ready` 1 to 0), marking nothing. Dropping an article (with the flag), `alt_snapshot_folder`, and a `sync_method` change between `native`, `character` and `database snapshot` also leave `immediate_sync_ready = 0` with no subscription awaiting anything.
- Source: measured, `15-snapshot-scope B.*.1a`, `B.*.1b`, `C.*.droparticle`, `C.*.alt_snapshot_folder`, `C.*.immediate_sync_false`, `C.character.sync_method`, `C.dbsnap.sync_method`.

### Reverse directions

- Expected: changing a property back to its default asks the same flags as the change away from it, or none.
- Observed: no reverse change asked `@force_reinit_subscription` (20608 appears in no cell). On a ready snapshot (`immediate_sync_ready = 1`, subscription at status 2) the location and script properties ask the invalidate flag, `f00=20607,f10=ok,f01=20607,f11=ok`: `alt_snapshot_folder` set to NULL or empty, `pre_snapshot_script` and `post_snapshot_script` set to NULL or empty, article `creation_script` set to NULL or empty, and `snapshot_in_defaultfolder` set to true. Everything else is accepted in all four cells, `allow_drop` false included: `allow_initialize_from_backup`, `allow_partition_switch`, `allow_pull`, `allow_subscription_copy`, `replicate_ddl`, `replicate_partition_switch` (false, then true again), the article `fire_triggers_on_snapshot` and the article `status` values `no column names` and `parameters`. On a publication whose snapshot is not ready (state N, status 2) every one of these rows is accepted in all four cells. On a publication without subscription (state P) `allow_push` true then false and `status = 'active'` are accepted in all four cells.
- Source: measured, `18-reverse RV.I.*`, `RV.N.*`, `RV.P.*` (45 rows, commit `745a6c5`).

### sync_method changes

- Expected: Learn says a `sync_method` change needs a new snapshot only.
- Observed: a change from or to `concurrent` or `concurrent_c`, between those two included, needs the reinitialization flag and marks every subscription row (status 1); a change between `native`, `character` and `database snapshot` marks nothing and needs at most the snapshot flag. A change to or from `concurrent` on a publication whose snapshot never ran is accepted with no flag, and `native` to `database snapshot` with no flag on a publication without `immediate_sync`, the snapshot that follows unmeasured.
- Source: measured, `02-matrix P21`, `P22`; `15-snapshot-scope C.*.sync_method`, `D.non_concurrent.sync_method_probe`, `D.*_pub.change`; `O9`, `O10`.

### sp_addarticle on an immediate_sync publication

- Expected: the new article must be subscribed explicitly, and the next snapshot covers the new article.
- Observed: `sp_addarticle` subscribes the existing subscriptions at once (refused without the snapshot flag when the snapshot is ready, 20607). The next snapshot regenerates every article of the publication, under every `sync_method`, and delivers only the new one. Without `immediate_sync` the subscriptions are not extended, `sp_addsubscription @article` is needed, and the next run generates the new article alone.
- Source: measured, lab rows 9 and 10 (`03-add-article C1`, `C2`), `15-snapshot-scope A.imm.*`, `A.non.*`, `06-structural C3.*`, `C4.*`.

### Extending a subscription to a new article

- Expected: `sp_addsubscription @article = '<name>'` adds one article to a subscription.
- Observed: on an `immediate_sync` publication any explicit extension is refused, with `'all'` by 14058 ("already exists"), by name by 14122 under `native` and 14100 under `concurrent`, whether or not anything is marked. On a `concurrent` or `concurrent_c` publication without `immediate_sync`, a named extension is refused with 14100 and `'all'` is the way, which delivers only the new article. These are static rules, not effects of a reinitialization mark: they repeat after a snapshot.
- Source: measured, `15-snapshot-scope D.imm_native.*`, `D.imm_concurrent.*`, `D.non_native_pub.extend`, `D.non_concurrent_pub.extend`, `D.*.extend_after_snapshot`; `O8` (Mistral); panel 3 GLM item 3 (14100 on `immediate_sync` plus `concurrent`, 14122 on `immediate_sync` plus `native`).

### A subset subscription with replication support only

- Expected: a subscription to one article out of three on an `immediate_sync` publication is refused with 14122 under automatic initialization, and the same under `replication support only`.
- Observed: `sp_addsubscription` of one article out of three on an `immediate_sync` publication with `@sync_type = N'replication support only'` returned 0. A single observation, not yet a measured row: it awaits a campaign row before the planner relies on it.
- Source: measured once, plan 3 task 8 review (2026-11-12).

### Re-adding a subscription with @article = 'all'

- Expected: `@article = 'all'` re-creates the subscription the user had.
- Observed: it subscribes every article. A subscription to one article of two, dropped with `'all'` and re-added with `'all'`, came back subscribed to both.
- Source: measured, `O11` (codex neutral).

### Completing a subscription with @article = 'all'

- Expected: Learn says that the subscription to one article of an `immediate_sync` publication cannot be added back unless the subscriptions to all articles are dropped and re-added; one would expect a refusal, or a delivery of the missing article.
- Observed: on a ready `immediate_sync` publication, after `sp_dropsubscription @article` of one article and an insert into it, `sp_addsubscription @article = N'all'` is accepted, puts the article back at status 2 at once and leaves `immediate_sync_ready` at 1: no snapshot runs, the row inserted in the gap never reaches the subscriber, and nothing reads as pending.
- Source: measured, panel 3 Opus, verified item 1; plan 3 rule R35. The `concurrent` case is not measured.

### Extending a pull or a replication support only subscription

- Expected: `sp_addsubscription @article` on an existing subscription extends that subscription as it is.
- Observed: without `@subscription_type` and `@sync_type`, extending a pull subscription creates a push row (`subscription_type` 0) and a second distribution agent with a running push job beside the pull one, and extending a replication support only subscription adds a `sync_type` 1 row at status 1 beside the `sync_type` 2 rows. With both parameters passed, the extension is a pull row at status 1 with no second agent, or a `sync_type` 2 row at status 2.
- Source: measured, panel 3 Fable, verified item 1; measured again with both parameters during the fold of plan 3 (rule R36).
- Observed again, with the output kept: a pull subscription to `t1` added with `@subscription_type = N'pull'`, then `sp_addsubscription @article = N't2'` with `@subscription_type = N'pull'` and `@sync_type = N'automatic'`. `MSdistribution_agents` had one row for the database pair before and after, and `syssubscriptions` had `t1` and `t2` both at status 1, `subscription_type` 1, `sync_type` 1. The call works only when it passes the subscription's own two parameters; without them (above) it creates a push row and a second agent. `m5` measured the passing case only; the case without the parameters is the earlier measurement.
- Source of this paragraph: measured, `plan3-fold-review m5` (`agents_after_pull_add`, `agents_after_extend`, `rows`).

## Snapshot runs and their history

### A run with nothing to generate

- Expected: a run that generates nothing is told apart from a generation by a status or a counter.
- Observed: a run that finds no subscription to initialize ends with runstatus 2, like a generation. Both write runstatus 1, 3 and 2; on both final rows `delivered_transactions`, `delivered_commands`, `delivery_rate` and `error_id` are 0, and `duration` is not reliable. Only the bulk copy row of a generation has `delivered_commands` above 0, and that row is 0 for an empty table and absent for a schema-only publication. Only the English text of the final row tells them: "[0%] A snapshot was not generated because no subscriptions needed initialization." against "[100%] A snapshot of 1 article(s) was generated." The history cleanup keeps only recent rows (`history_retention`), so the retained history of a publication with a recurring schedule may hold no generation at all; that last point is by reading.
- Source: measured, p2 task-11-fix-1-report (both runs listed row by row), `internal/reader/queries.go:314-322`, lab test `TestReadLabLastGeneration`; `README.md` "Runtime facts" for the retention.

### Every run of an immediate_sync publication

- Expected: a scheduled snapshot agent generates only what someone awaits.
- Observed: an `immediate_sync` publication generates every article at every run. The default schedule of `sp_addpublication_snapshot` is every 5 minutes: `SalesPub` generated its 2 articles at each of 12 runs in an hour, `SalesRef` (no `immediate_sync`) none. Each run also writes new snapshot commands into `MSrepl_commands` for a subscription that awaits nothing.
- Source: measured, design "Blocking" (lab count); `lab/README.md` "Observed outside the campaign".

### immediate_sync_ready on a new publication

- Expected: `immediate_sync_ready` is 1 once the publication and its snapshot agent exist.
- Observed: it is 0 until the first run of the snapshot agent; a lab just rebuilt reads `SalesPub` as not ready until its first scheduled run. A later run sets it back to 1 after an invalidation (`sp_MSactivate_auto_sub`, by reading the 2019 source).
- Source: measured, panel 3 Fable, verified item 3; the `sp_MSactivate_auto_sub` part by reading, design "Strategies".

### Restoring immediate_sync too early

- Expected: turning `immediate_sync` back on after a run that generated one new article changes nothing for that run.
- Observed: restored while the agent was still starting (798 and 558 ms before its first history line), `immediate_sync` made the run generate every article again, although only the new one was delivered. A restore after the generation and before any delivery, both agents disabled, still delivered the new article alone. A restore committed during the generation is not measured.
- Source: measured, `15-snapshot-scope B.native_race.race`, `B.concurrent_race.race`; `O15` (Claude, one run under `native`).

### Latest generation folder and last delivered folder

- Expected: a subscription whose last delivered folder is older than the latest generation awaits a delivery.
- Observed: on an `immediate_sync` publication every run makes a new folder that the existing subscriptions never receive: `SalesPub` had generated three folders in 15 minutes while its subscription, awaiting nothing, last delivered a folder of the morning.
- Source: measured, read-only, `lab/README.md` "Observed outside the campaign" (2026-11-11 14:32 UTC).

### Run folder names and times

- Expected: the run folder carries a creation time.
- Observed: a run folder is named after the distributor's clock, to the second, between the run's "Starting agent" and "Initializing" history lines (eight runs, two publications). `sys.dm_os_enumerate_filesystem` gives it no creation time (it reads 1601-01-01), so the name is the only time a folder carries. Whether the name is local time or UTC is not known: the lab runs in UTC.
- Source: measured, `lab/README.md` "Observed outside the campaign" (15:52 UTC reading), `O19`.

### The Delivered snapshot line

- Expected: the distribution history names the folder the files came from.
- Observed: the line "Delivered snapshot from the 'unc\<name>\<timestamp>\' sub-folder in n milliseconds" names the run folder, for a shared agent too. It keeps that relative `unc\` path even when the files are under `alt_snapshot_folder`; a space in a publication name is kept in the folder name.
- Source: measured, `16-snapshot-report-sources RS.*.distribution_history`; `O19`.

### Folder name on a named instance

- Expected: the folder is named `<server>_<database>_<publication>`.
- Observed (by reading, not measured): on a Windows named instance the snapshot agent writes `SERVER$INSTANCE_DB_PUBLICATION`, the backslash replaced by `$`. From field experience of the plan 1 final reviewer; the lab is a default instance.
- Source: by reading, p1 final-review.md line 34.

### Distribution history watermark

- Expected: the `xact_seqno` of a distribution agent's last history row is its position.
- Observed: after a delivery, the "Bulk copied" and "Delivered snapshot" rows kept the old `xact_seqno` for 3.5 minutes, until the agent's next idle row, while the subscriber's `MSreplication_subscriptions.transaction_timestamp` already had the new value; the history never catches up if the agent stops first. Two of 14 start rows carried `xact_seqno` 0x0. New snapshot commands of a scheduled run stay beyond the history watermark until the agent's next history write.
- Source: measured, `O2` (Claude); `lab/README.md` "Observed outside the campaign" (task 12 review reading).

### History rows rewritten in place

- Expected: the distribution history is append-only.
- Observed (by reading, not measured): `sp_MSadd_distribution_history` rewrites the agent's last history row in place, its comments, time and rowversion with it, when that row is updateable and the new message is idle, or both messages are idle or in progress. A row written before a mark can come back above it with a new text, and a "Delivered snapshot" row may be overwritten by the next message. The history cleanup keeps one row per agent.
- Source: by reading, `[R] sp_MSadd_distribution_history`, `sp_MShistory_cleanup` (panel Claude), design "Deliveries owed" and "Inputs". Campaign item 14 is to measure it.

### Virtual subscriber rows of MSsubscriptions

- Expected: `MSsubscriptions` has one row per real subscribed article.
- Observed: it also has rows for the virtual subscribers -1 and -2. On an `immediate_sync` publication the -1 row gets a new window (`subscription_seqno`, `ss_cplt_seqno`) at every scheduled run. The -2 row (anonymous) is updated only while `snapshot_seqno_flag = 0` or its status is 1 or 3, so with `allow_anonymous` false it kept its first window. A query that joins by publication rather than by the subscription's own rows mixes them in (6 rows instead of 2 for `SalesPub`).
- Source: measured, `O3` (GLM, Claude); the update rule by reading `[R] sp_MSset_snapshot_xact_seqno`; `internal/reader/queries.go:297-301`; p2 task-11-report break step.

### The window of a new subscription

- Expected: `sp_addsubscription` writes the new subscription's window.
- Observed: on an `immediate_sync` publication, `sp_MSupdate_subscription` copies it from the virtual row when the distribution agent activates the subscription, and copies the window the virtual row holds at that moment. A subscription added when run 1 was the only generation received run 2. Until activation the subscription has no window.
- Source: measured, `O4` (GLM); `sp_MSupdate_subscription` by reading.

### Snapshot commands of the window

- Expected: every snapshot command of an article is a candidate for delivery.
- Observed (partly by reading): the 2019 source of `sp_MSget_repl_commands` takes a snapshot command for a subscribed article when its `xact_seqno` lies between that article's `subscription_seqno` and `ss_cplt_seqno`, plus header and trailer commands outside it. All of `SalesPub`'s scheduled snapshot commands lay outside its subscription's window (248 and 242 beyond, none before). The snapshot commands of dropped articles stay in `MSrepl_commands` until the distribution cleanup removes them.
- Source: by reading `[R] sp_MSget_repl_commands`; measured read-only, `lab/README.md` "Observed outside the campaign" (14:54 UTC) and "Lab residue"; `O5`.

### Status 3 under concurrent sync

- Expected: a generated `concurrent` snapshot is delivered by the distribution agent like any other.
- Observed: with the log reader stopped, a generated `concurrent` publication read status 2 and the active bit at the publisher, while its rows of `distribution.dbo.MSsubscriptions` were at status 3; the agent logged "The concurrent snapshot for publication ... is not available because it has not been fully generated or the Log Reader Agent is not running to activate it", and the subscriber table did not exist. Once the log reader ran, the rows went to 2 and the delivery came. Status 3 is only ever read in `MSsubscriptions`, never in `syssubscriptions`, and comes before the delivery.
- Source: measured, `O18` (fix review); `internal/reader/queries.go:147-149`.

### Delivery failure under database snapshot

- Expected: a just-added article is delivered under `database snapshot` as under `native`.
- Observed: in some runs the delivery failed with "Could not find stored procedure 'dbo.sp_MSupd_dbom_t3'"; the variants built to reproduce it all delivered. Cause unknown.
- Source: measured, round 1 `15-snapshot-scope A.imm.dbsnap` (`git show 8db6060:lab/results/2022/15-snapshot-scope.txt`) and two development runs of `A.non.dbsnap`; not reproduced by `F.*`.

### Snapshot scripts on Linux

- Expected: a publication with a `pre_snapshot_script` or `post_snapshot_script` initializes a subscription like any other.
- Observed: on the Linux lab the distribution agent cannot apply a snapshot that has a pre- or post-snapshot script. It fails with "Failed to obtain the SQL Server utilities installation path from the registry" (`MSrepl_errors` names the `ReplAlt\unc\...\m_rv_pre_0.sql` file of the run), retries, and never delivers. The lab campaign therefore sets the scripts after the delivery (`sp_changepublication` and `sp_changearticle` with `@force_invalidate_snapshot = 1, @force_reinit_subscription = 0`, which leaves the subscription at status 2) and generates the snapshot again.
- Source: measured, plan 3 task 1 setup (`.superpowers/sdd/2026-11-12-sqlrepl-3-planner/task-1-3-report.md`), where `18-reverse` hit it. Not measured on Windows.

### Two snapshot starts at once

- Expected: two `sp_startpublication_snapshot` calls at once either queue or the second is refused (see the next entry).
- Observed: started at once, they deadlock one snapshot agent, whose history shows runstatus 5; it retries.
- Source: measured, plan 3 task 7 review, measured. The report is not in the repository, and the ledger line does not show the deadlock message.

### Starting a snapshot agent that is already running

- Expected: `sp_startpublication_snapshot` raises an error when the job is already running.
- Observed: it returns 1 with `@@ERROR` 0 and nothing for `TRY...CATCH`. The only message is an informational "HResult 0x5606, Level 16, State 1" line followed by the Agent's "Request to run job ... refused because the job is already running", not a `Msg` line. A second start right after a run's runstatus 2 row, while the job is still finishing, is refused the same way.
- Source: measured, `16-snapshot-report-sources RS.*.start_running` under three methods; p2 task-11-fix-1-report.

### Calls refused during a run

- Expected: replication calls queue behind a running snapshot or are refused alike.
- Observed: while a run is generating, `sp_addarticle` on an `immediate_sync` publication is refused with 21854 ("a snapshot is being generated"), `sp_articlefilter` with 21861 then 14070, keeping the old filter procedure, and `sp_addsubscription` waited 18 s, returning when the run ended.
- Source: measured, `O17` (fix review).

### History times

- Expected: the snapshot history times are the times of the events.
- Observed: they are the times the agent wrote the rows: they come in bursts a few milliseconds apart. Under `database snapshot` the writers were released 600 ms before the "Locking published tables" line was written.
- Source: measured, `15-snapshot-scope A.imm.dbsnap`; design "Blocking".

### Per-article lines under concurrent sync

- Expected (from the review of e220523): no per-article lines under `concurrent`.
- Observed: the snapshot history has per-article bulk copy and schema lines under every method, `concurrent` included. The distribution history has one "Bulk copied data into table" line per bcp partition, whose sums equal the source row counts.
- Source: measured, `16-snapshot-report-sources RS.*.snapshot_history`, `RS.*.distribution_history`.

## Blocking during a snapshot

### native and character locks

- Expected: each table is locked while it is copied.
- Observed: the generated tables are locked together, from shortly before the "Locking published tables" line to the history's last line, between a third and two thirds of the run (`native` 2044 ms of 3990, `character` 3002 of 4920). A 100-row table copied in 40 ms waited as long as the 1M-row table in the review. Tables the run does not generate are not locked.
- Source: measured, `15-snapshot-scope A.imm.native`, `A.imm.character`, `A.non.native`, `A.non.character`.

### concurrent and concurrent_c locks

- Expected: concurrent snapshot processing does not block writers.
- Observed: it locks briefly near the start and near the end: under `concurrent` 62 and 70 ms near the start and about 100 ms at the end; under `concurrent_c` about 50 ms near the start, 68 to 260 ms of `LCK_M_IX` held by the snapshot job's session, and 72 to 97 ms before the last history line. Writers also stalled after the last history line, 207 ms about 1.9 s later, 252 to 284 ms 4.9 s later with no lock wait sampled, and under load an `UPDATE` ended 8.4 s after it. What those late stalls wait on is not known. Under `concurrent` the writer's longest `UPDATE` (101 ms) held 24 ms of lock wait; the rest was a log flush.
- Source: measured, `15-snapshot-scope A.non.concurrent`, `A.imm.concurrent`, `A.non.concurrent_c`, `A.imm.concurrent_c`; `O12` (Claude, Mistral); `16-snapshot-report-sources RS.concurrent.sampling_250ms`.

### database snapshot locks

- Expected: no lock, since the snapshot reads a database snapshot.
- Observed: writers wait about 200 ms near the start, while the database snapshot is created (211 ms, 109 to 195 ms, 321 ms on the new table), and not after.
- Source: measured, `15-snapshot-scope A.imm.dbsnap`, `F.imm_dbsnap_1` to `_3`, `A.non.dbsnap`.

### Sampling the blocking

- Expected: sampling `sys.dm_exec_requests` and `sys.dm_os_waiting_tasks` every second sees a multi-second lock.
- Observed: at 1 s, a 2462 ms native wait read as 1554 ms and a 289 ms wait under `database snapshot` was missed; at 250 ms they read 2376 and 36 ms.
- Source: measured, `16-snapshot-report-sources RS.native.sampling_1s`, `RS.native.sampling_250ms`, `RS.dbsnap.sampling_*`.

### Sessions of the agents

- Expected: every session of a snapshot or distribution agent names its publication.
- Observed: the snapshot agent's sessions carry the snapshot job's name (equal to `MSsnapshot_agents.name`), `SQLAgent - TSQL JobStep (Job <id> : Step n)`, "Snapshot Agent Distributor Connection for publication '<server>:<database>:<publication>'", "Snapshot BCP thread #n for publication <name>" and, under `database snapshot`, "Database snapshot creation connection for publication <name>", but "Snapshot Agent Smo Connection" names none. An independent distribution agent's sessions are `<instance>_<publisher_db>_<publication>`, a shared one's `<instance>_<publisher_db>` (`repllab_Sales`), which cannot be told from another shared agent's.
- Source: measured, `16-snapshot-report-sources RS.*.program_names`.

## Initialization without a snapshot

### Re-adding a replication support only subscription

- Expected: dropping and re-adding a "replication support only" subscription resumes it.
- Observed: the rows written between the drop and the re-add are lost silently.
- Source: measured, `10-init-modes I1.support-only.gap` (`missing=[111]`).

### Re-adding from the original backup or LSN

- Expected: re-adding with the original backup or LSN replays what is missing.
- Observed: it replays rows already delivered; the first duplicate stops the agent with 14151 (the 2627 primary key text inside), and it retries on the same row. A fresh `COPY_ONLY` backup restored over the subscriber, or `initialize from lsn` with the subscriber's `MSreplication_subscriptions.transaction_timestamp`, delivers every gap row (single-row transactions only).
- Source: measured, `10-init-modes I2.backup.gap-original`, `I3.lsn.gap-original`, `I2.backup.gap-fresh`, `I3.lsn.gap-resume`; p1 task-9-report.

### A wrong LSN

- Expected: `sp_addsubscription @sync_type = 'initialize from lsn'` with a wrong LSN is refused.
- Observed: it was accepted silently and wrote `MSrepl_transactions` rows that moved the watermark of every idle distribution agent of the publisher database: every subscription of `Sales` stopped without an error, and dropping the subscription did not repair it. The lab was recreated.
- Source: measured during the development of `10-init-modes`, `lab/README.md` "Initialization without a snapshot", `lab/campaign/10-init-modes.sh:52-55`.

### Converting an LSN

- Expected: `CAST(lsn / 1e15 AS binary(4)) + ...` gives the binary LSN.
- Observed: a cast of a numeric to `binary` gives the numeric's internal bytes, not the three integers; the conversion needs exact modulo arithmetic through `bigint`.
- Source: measured, `10-init-modes I3.lsn.create` (`brief_formula_matches=no`), `lab/campaign/10-init-modes.sh:45-50`.

## Push subscriptions

### The implicit distribution agent job

- Expected: `sp_addsubscription` registers the subscription and `sp_addpushsubscription_agent` creates its agent.
- Observed: `sp_addsubscription` of a push subscription creates and starts the distribution agent job by itself, printing "The distribution agent job has been implicitly created and will run under the SQL Server Agent Service Account", and that job delivered the snapshot about 5 s later. The `sp_addpushsubscription_agent` that follows returns 0 and updates the same job (same name, schedule changed from continuous to the one given). Between the two calls the agent runs under the Agent service account. Measured on 2022 only.
- Also observed: on a publication with `independent_agent`, `sp_addsubscription` starts the distribution job at once, even for an unreachable subscriber. A pull subscription at an unreachable subscriber reads, from the publisher, as a job NULL with "Distribution agent for subscription added.". Source: plan 3 task 4 and task 5 reviews, measured; the ledger lines do not show where that message appears.
- Also observed: the same happens when `sp_addsubscription` is given schedule or security parameters (`@frequency_*`, `@subscriber_security_mode`, `@subscriber_login`, `@subscriber_password`). It prints "The parameters for security, batch size, and scheduling have been deprecated and should no longer be used", then creates the distribution agent job implicitly; a following `sp_addpushsubscription_agent` returns 0 and updates the same job. Source: plan 3 task 8 review, measured (2026-11-12).
- Source: measured, `O13` (Claude, controller); p2 task-11-fix-1-report (the same warning on `m_gen`).

### sp_addsubscription in a transaction

- Expected: it can run in a transaction rolled back for measurement.
- Observed: refused with 15002.
- Source: measured, the panel and the campaign scripts (design "Measurement campaign"; `lab/campaign/09-snapshot-pub.sh:93`).

### Subscriber registration

- Expected: `sp_dropsubscriber` undoes the registration `sp_addsubscription` made.
- Observed: `sp_addsubscription` to an unregistered server registers it (`MSsubscriber_info.type` 0) and adds a `sys.servers` row. `sp_dropsubscriber` ("The Subscriber was dropped.") leaves the `sys.servers` row, which only `sp_dropserver` removes. A refused `sp_addsubscription` (14124, no article) also leaves the `sys.servers` and `MSsubscriber_info` rows.
- Also observed: `sp_addsubscription` of a pull subscription for an unknown server adds `sys.servers` and `MSreplservers` rows. `sp_dropsubscriber` only clears `is_subscriber`. The `MSreplservers` rows survive everything: no procedure deletes them, and the lab keeps `RV_T4F0D5_GHOST`, `RV_COPUSK7Q2_FRESH` and `M_FRESHSUB` as residue, harmless.
- Source: measured, panel 3 Opus, verified item 5; plan 3 task 4 review, measured.

### sp_addsubscription without @subscriber

- Expected: refused by `sp_addsubscription` with its own message.
- Observed: refused with 14043 from an inner procedure: "@subscriber passed to stored procedure sp_MSrepl_addsubscriber cannot be NULL".
- Source: measured, panel 2 Claude, verified item 7.

### Dropping a whole subscription and its arguments

- Expected: `sp_dropsubscription @article = NULL` drops the whole subscription.
- Observed: refused with 14043; `@article = N'all'` is the call, which drops the subscription, its agent row and its job with no flag.
- Source: measured, the panel (design "Subscriptions"); `06-structural C1.*`.

### A shared distribution agent

- Expected: a shared agent exists as long as its publications exist.
- Observed: it is created with the first subscription that uses it and disappears, job included, with the last; it survives the drop of the first of two.
- Source: measured, `07-changes SHR.after1`, `SHR.after2`.

### sp_changesubscription

- Expected: it changes the subscription and its job.
- Observed: it changes the distribution agent row only. The heterogeneous properties (`subscriber_type`, `subscriber_catalog`, `subscriber_datasource`, `subscriber_location`, `subscriber_provider`, `subscriber_providerstring`) are refused with 14041; an unknown property with 21183.
- Source: measured, `07-changes SUB.*`.

### sp_changesubscriber

- Expected: Learn says "Any distribution task for the Subscribers to this Publisher is updated".
- Observed: it writes `MSsubscriber_info` and `MSsubscriber_schedule` only; no job, job step, schedule or agent row changes, for any of the 19 parameters.
- Source: measured, `07-changes SBR.*`; p1 task-6-report.

## Pull subscriptions

### @subscription_type at the subscriber

- Expected: `sp_addpullsubscription` without `@subscription_type` creates a named pull subscription, the publisher already knowing it as pull.
- Observed: on 2022 the subscriber records an anonymous subscription (type 2) while the publisher and the distributor have a named pull, and the agent fails with 21084 ("does not allow anonymous subscriptions"). The 2019 source raises 20016 instead (by reading).
- Source: measured, `08-pull P1.omitted`; `[R] sp_addpullsubscription.sql:151`.

### An anonymous row beside the named one

- Expected: one row per publication in `MSreplication_subscriptions`.
- Observed: an anonymous row (type 2) can stand beside the type 1 row, since the unique index `uc1MSReplication_subscriptions` includes `subscription_type`.
- Source: measured by the fix review of plan 2's panel fold (p2 triage, last section); `internal/reader/queries.go:425-428`.

### independent_agent and immediate_sync at the subscriber

- Expected: the values `sp_addpullsubscription` stores are copies of the publication's.
- Observed: they are parameters that default to 1. On a publication with `immediate_sync = 0`, an omitted `@immediate_sync` stores 1 at the subscriber.
- Source: measured, panel 2 Claude, codex directive, GLM, Mistral (each verified item 1); `11-defaults D.sp_addpullsubscription.pull.@immediate_sync`; `internal/reader/agents.go:756-758`.

### Required parameters of the pull procedures

- Expected: `@publisher` of `sp_addpullsubscription` names a non-SQL Server publisher, as on other procedures.
- Observed: `sp_addpullsubscription` and `sp_addpullsubscription_agent` both require `@publisher` for an ordinary pull subscription (`IF @publisher IS NULL` in their definitions), and `sp_addpullsubscription_agent` also requires `@publisher_db` and `@publication` (error 201).
- Source: measured, panel 2 codex neutral, verified item 1; p2 triage, fix review of the fold.

### The pull agent's job login

- Expected: `MSsubscription_properties.job_login` holds the job account given as `@job_login`.
- Observed: `sp_addpullsubscription_agent` passes `@job_login` to the job it creates but stores `@cl_login` in that column, which it sets only on edition 32 (`fn_MSrepl_editionid() = 32`). `sp_helppullsubscription` reads the account from the job step's proxy credential.
- Source: by reading the 2022 CU27 definitions on the lab, panel 2 codex neutral, verified item 2; plan 2 "Rulings made in this plan".

### Deprecated subscriber security parameters

- Expected: `sp_addpullsubscription_agent @subscriber_security_mode = 0, @subscriber_login, @subscriber_password` makes the agent connect to the subscriber with SQL authentication.
- Observed: it prints "parameters have been deprecated" and still writes `-SubscriberSecurityMode 1` in the job step. `sp_change_subscription_properties` refuses `subscriber_security_mode` and `subscriber_login` with 3217.
- Source: measured, p2 task-10-report "Measurements on the lab".

### FTP and publisher parameters of a pull agent

- Expected: `@ftp_address`, `@ftp_port`, `@ftp_login`, `@ftp_password` of `sp_addpullsubscription_agent` are stored.
- Observed: they are inserted as NULL whatever is passed (and the publisher login and password as NULL, `publisher_security_mode` -1). `sp_change_subscription_properties` accepts the `ftp_*` properties and reads back NULL; it refuses `publisher_login`, `publisher_password`, `publisher_security_mode` and `dynamic_snapshot_location` with 3217.
- Source: by reading `[R] sp_addpullsubscription_agent.sql:754-767`; measured, `08-pull P2.ftp_*`, `P2.publisher_*`, `P2.dynamic_snapshot_location`; `internal/model/parameters.go:391`.

### sp_change_subscription_properties

- Expected: the property list of Learn, and Learn's statement that a NULL `dts_package_password` leaves the password unchanged.
- Observed: `distributor` and `memory_optimized` are accepted though Learn does not list them; `offload_agent` and `offload_server` are refused with 21698 ("no longer supported"); a NULL `dts_package_password` is refused with 21732.
- Source: measured, `08-pull P2.distributor`, `P2.memory_optimized`, `P2.offload_*`, `P2.dts_package_password`.

### Where a pull agent's settings live

- Expected: a pull agent's settings are at the subscriber, its job referenced at the distributor.
- Observed: the distributor keeps a `MSdistribution_agents` row for a pull agent (type 1, with its profile), whose `job_id` is 0: the job is at the subscriber, referenced by `MSreplication_subscriptions.agent_id` and the step uid. `@subscriptionstreams` and `@memory_optimized` of a pull subscription are set by `sp_addsubscription` at the publisher and stored in that distributor row; the pull procedures have no such parameters. The pull job step carries no `-DistributorSecurityMode` or `-DistributorLogin`: the distributor connection is in `MSsubscription_properties`, where an empty `distributor_login` is `''`, not NULL. `MSreplication_subscriptions.publisher` is lower case (`repllab`).
- Source: measured, `08-pull P1.named`, `G1.orphan-guard`; `11-defaults D.sp_addsubscription.pull.@subscriptionstreams`, `.@memory_optimized`; p2 final-fix-report item 10; p2 task-10-report.

### A shared pull agent

- Expected: one pull agent per subscription.
- Observed: for publications without an independent agent, one pull agent serves every subscription of the subscriber database (one job, the same `agent_id` and `job_step_uid` in every row), recorded at the distributor with `publication = N'ALL'` and `subscription_type` 1. `sp_addpullsubscription` registers a row without an agent; the row gets one only through `sp_addpullsubscription_agent`, so a publication whose agent was added for another one has a NULL `agent_id` and no `MSsubscription_properties` row.
- Source: measured, two reviewers of plan 2 Task 10, `internal/reader/agents.go:474-477`, `:543-547`; p2 task-10-report.

### Dropping a shared pull agent

- Expected: `sp_droppullsubscription` of the last subscription drops the shared agent's job.
- Observed: it prints that the job "was not removed because it has a non-standard name" and leaves it; `sp_delete_job` removes it.
- Source: measured twice, ledger 2 line 61; p2 task-10-report.

### The order of a pull drop

- Expected: either end can be dropped first.
- Observed: subscriber first (`sp_droppullsubscription`, then `sp_dropsubscription`) leaves nothing at any step. Publisher first leaves the pull agent running and logging "Agent message code 21021. The subscription does not exist." until the subscriber drop.
- Source: measured, `08-pull P3.*`.

### Where the pull procedures run

- Expected: `sp_addpullsubscription` runs in the subscription database only.
- Observed: it is refused only in `master` (21481); it runs in `msdb` and in `distribution`. `sp_addpullsubscription_agent` after the refusal in `master` gives 20017.
- Source: measured, `12-contexts X.sp_addpullsubscription.*`.

## Agents and jobs

### No agent procedure takes a profile

- Expected: `sp_addlogreader_agent`, `sp_addpublication_snapshot` and `sp_addpushsubscription_agent` accept a profile.
- Observed: none does; an agent is created on the default profile of its type and bound later with `sp_update_agent_profile`.
- Source: measured from `sys.all_parameters` and read in the sources, the panel (design "Agents and profiles").

### sp_update_agent_profile and its database

- Expected: `msdb.dbo.sp_update_agent_profile`, since the procedure lives in `msdb`.
- Observed: called as `msdb.dbo.sp_update_agent_profile` it executes in `msdb` whatever the current database and refuses with 21482 ("can only be executed in the distribution database"). `distribution.dbo.sp_update_agent_profile` works, and so does the plain name from the distribution database.
- Source: measured, `07-changes PRF.*`.

### Job account changes

- Expected: `job_login` accepts any account, and `job_password` can be changed alone.
- Observed: `job_login` needs a valid Windows account ("Proxy ... is not a valid Windows user", 14529); `job_password` alone is refused with the generic error 50000, "@job_login must be a non-null/non-empty value". `job_security_mode` is refused with 41989, Managed Instance only. Their effect on proxies is not measured (the lab is on Linux).
- Source: measured, `07-changes AGT.*.job_login`, `AGT.*.job_password`, `AGT.*.job_security_mode`; `08-pull P2.distrib_job_*`.

### The login in an agent command line

- Expected: the server quotes the values of the switches it writes, as it brackets the server names (`-Publisher [REPLLAB]`).
- Observed: `-DistributorLogin` and `-DistributorPassword` are written raw, unquoted: " -DistributorLogin <login> -DistributorPassword <password>". A login containing a space, a quote or a switch-like text cannot be told from the rest of the line, and the password appears in clear in `sysjobsteps.command`.
- Source: measured by both reviewers of plan 2 Task 7, ledger 2 lines 45 and 47; `internal/reader/agents.go:239-245`, `reader.go:528-532`.

### A proxy on the snapshot job

- Expected: `sp_droppublication` drops the snapshot job and leaves the user's Agent proxy alone.
- Observed: dropping a publication deletes an Agent proxy the user set on its snapshot job step, together with the job.
- Source: measured twice by the reviewer of plan 2 Task 7, ledger 2 line 48.

### A snapshot agent never added

- Expected: no `MSsnapshot_agents` row until `sp_addpublication_snapshot`.
- Observed: `sp_addpublication` alone registers a row with `local_job = 0` and the `job_id` of a job that does not exist (`msdb.dbo.sysjobs` has no such row). `sp_update_job` on that id fails with 14262 ("The specified @job_id ... does not exist"); the measured call used a random `binary(16)` that names no job, which is the same case as the stored id, not the stored id itself. After `sp_addpublication_snapshot` the same row (still one row for the database) has `local_job = 1` and a new `job_id` that names an existing job, and `sp_update_job @enabled = 0` then `1` on that `binary(16)` value passes (return code 0, `enabled` 0 then 1).
- Source: measured, `01-articles A1`; `internal/reader/queries.go:226-228`; `plan3-fold-review m3` (`snapagent_before`), `m4` (`snapagent_after`, `update_job_binary`, `update_job_restore`, `update_dead_err`).

### job_id of a deleted job

- Expected: the `job_id` kept by the replication tables names an existing job.
- Observed (by reading): it is `binary(16)`, must be converted to `uniqueidentifier`, and can outlive a deleted job.
- Source: by reading `[R] sp_MSenumdistributionagentproperties.sql:78-93`, `sp_MShelpsnapshot_agent.sql:57`; `internal/reader/queries.go:247-248`.

### Disabled jobs

- Expected: disabling a job stops it and keeps it from starting.
- Observed: a disabled job that is running keeps running, to its end; `sp_start_job` starts a disabled job (return code 0); `sp_startpublication_snapshot` also starts a disabled snapshot job (return code 0, `@@ERROR` 0, 12 history rows), and `sp_changepublication_snapshot` changes its schedule and leaves it disabled. Whether a disabled job's schedule starts a run is not measured.
- Source: measured, lab README "When the flags are needed" (`sp_stop_job` needed), `O20`, `O21`.

### sp_stop_job on a job that has just ended

- Expected: inside `TRY`, a refusal goes to the `CATCH`.
- Observed: `sp_stop_job` on a job that has just ended prints its refusal past `TRY`.
- Source: measured while writing the campaign, `lab/campaign/05-snapshot-flag.sh:210-211`.

### snapshot_job_name of sp_changepublication_snapshot

- Expected: Learn describes `snapshot_job_name` as "the name of an existing job if an existing job is used"; one expects a rename or a switch of job.
- Observed: the call is accepted, the job name is unchanged and the `sysjobs` row is bumped.
- Source: measured, `07-changes AGT.sp_changepublication_snapshot.snapshot_job_name`; p1 task-6-report.

### Retention changes and the cleanup jobs

- Expected: `sp_changedistributiondb` changes the retention in `msdb.dbo.MSdistributiondbs`.
- Observed: changing `min_distretention`, `max_distretention` or `history_retention` also changes the cleanup jobs and their steps, and the row records that the jobs still differ after the value is restored (what differs is not recorded).
- Source: measured, `07-changes DST.sp_changedistributiondb.*` (`changed_inside=[distributor,jobs,steps] after_restore_differs=[jobs]`).

## Agent history and errors

### runstatus 5

- Expected: a history row of runstatus 5 is a failure.
- Observed: it is a retry; the agent goes on. A runstatus 6 row is the failure.
- Source: measured by the plan 2 Task 11 reviewer (Opus), ledger 2 lines 67 and 71; plan 3 rule R13.

### A failed agent waiting for its retry

- Expected: a failed agent's job is not running.
- Observed: while it waits for its step retry, the job has a `sysjobactivity` row of the latest Agent session with a start and no stop, so it reads as running.
- Source: measured by the plan 2 Task 11 reviewer (Fable), ledger 2 lines 66 and 71; `internal/reader/queries.go:344-346`.

### The error of a history row

- Expected: `MSrepl_errors` row `id = error_id` of the history row is the cause of the failure.
- Observed: the id points to a wrapper message, and the cause is under the next id; one id holds several rows, a stack ordered by time. On the lab, distribution history `error_id` 1 is "Replication-Replication Distribution Subsystem: agent repllab-Sales-repllab-4 failed. Unable to replicate a view ..." (error code 14151), and id 2 holds the cause: 208 "Invalid object name 'dbo.Customer'", the failing `CREATE VIEW`, then the message. Id 3 is a stack of five rows for one log reader failure.
- Source: wrapper measured by the plan 2 Task 11 reviewer (Fable), ledger 2 line 66; the next id and the stack read on the lab, read-only, on 2026-11-12 while writing this document (one failure of each kind).

### An orphan history row

- Expected: dropping an agent removes its history.
- Observed: dropping a publication with its distribution agent running can leave one history row whose agent is gone, depending on whether the agent writes one more row after its agent row is gone; the same case showed both outcomes across runs.
- Source: measured, `13-transient T03` to `T06`, `T10` (`orphan_dist_history` 0 or 1), lab README "Reading the results files".

## Profiles

### A new profile

- Expected: `sp_add_agent_profile` creates an empty profile, filled with `sp_add_agent_parameter`.
- Observed: it copies the 12 parameters of the default profile of its type (`-CommitBatchSize` 100, `-QueryTimeout` 1800...), so `sp_add_agent_parameter` on any of them is refused with 20067 ("already exists for the specified profile"); `sp_change_agent_parameter` is the call.
- Source: measured by all six seats, panel 3 Opus, Fable, codex directive (verified item 2 each); `lab/setup.sql:96`; `19-profiles PF.copied_parameters` (12 parameters, same names and values as the template profile), `PF.add_copied_parameter` (20067 on `-CommitBatchSize`). See the next entry for which profile it copies.

### The profile a new profile copies

- Expected: the parameters come from the current default profile of the type.
- Observed: `sp_add_agent_profile` copies from the first system profile of the type (`MIN(profile_id) WHERE agent_type = @t AND type = 0`, `stored-procedures/sp_add_agent_profile.sql`), not from the current default. In the test a user profile of the Distribution Agent type (`agent_type` 3) with `-CommitBatchSize` changed to 500 and `-PacketSize` 8192 added was made the default (`@default = 1`); a profile created next got the 12 system parameters with the system values, so neither the 500 nor the `-PacketSize` appeared. This rests on the procedure source and on the result as recorded when the test was run: `m1.sql` has no output file in the folder, so the values cannot be re-read from it.
- Re-measured with an output file: `sp_add_agent_profile m_prof_def @default = 1` makes `m_prof_def` the default of type 3 (`def_profile` 1) and clears the flag of the previous default, so one profile has `def_profile = 1`. `m_prof3`, created afterwards, has 12 parameters with `-CommitBatchSize` 100, equal to the template and not equal to `m_prof_def`, whose value was 300.
- Source: by reading `stored-procedures/sp_add_agent_profile.sql`; measured, `plan3-fold-review m1` (script only, no output file); `19-profiles PF.create_default`, `PF.copy_after_user_default` (commit `2653ad6`).

### sp_change_agent_parameter on a missing parameter

- Expected: an error, as `sp_add_agent_parameter` raises 20067 for a parameter that exists.
- Observed: `sp_change_agent_parameter` on a parameter name the profile does not have returns 0 and changes nothing, with no error, so a typo in a parameter name is silent. The test changed `-OledbStreamThreshold` (and, in `m2`, `-PacketSize`) on a fresh profile, then counted the rows of that name: none were added. The output files are not in the folder (`m1.sql` and `m2.sql` only), so the return code and the count are as recorded when the test was run.
- Re-measured with an output file: `sp_change_agent_parameter -PacketSize = 8192` on a profile that has no such parameter returns 0 and adds no row (`-PacketSize` rows 0, parameters still 12). `sp_add_agent_parameter` is the call that adds it (parameters 13, and the template profile still has none). `sp_change_agent_parameter -CommitBatchSize = 200` changes the value (`MSagent_parameters.value` 200), and `sp_change_agent_profile description` changes `MSagent_profiles.description`.
- Source: measured, `plan3-fold-review m1`, `m2` (scripts only, no output file); `19-profiles PF.change_missing_parameter`, `PF.add_parameter`, `PF.change_parameter`, `PF.change_description`.

### Dropping a parameter and a profile

- Expected: only a parameter added by hand can be dropped, since the copied ones come from the default profile.
- Observed: `sp_drop_agent_parameter` works on a copied parameter: `-QueryTimeout` dropped from the copied profile leaves 11 parameters and no row of that name. `sp_drop_agent_profile` on an unused profile removes its row of `MSagent_profiles` and all its rows of `MSagent_parameters`.
- Source: measured, `19-profiles PF.drop_parameter`, `PF.drop_unused` (commit `2653ad6`).

### The default profile of a type

- Expected: `sp_change_agent_profile` can make a profile the default.
- Observed: it accepts only `description` (21183 "Invalid property name 'default'"), in the 2019 source and on 2022. The default is set by `sp_add_agent_profile @default` at creation, or by the internal `sys.sp_MSupdate_agenttype_default`, which no public procedure wraps.
- Also observed: `sys.sp_MSupdate_agenttype_default` resets the default of a type (plan 3 task 4 review, measured; the ledger line does not say to what). `sp_change_agent_profile` with `default` returns 21183 again in `19-profiles PF.change_default`.
- Source: measured, panel 3 codex directive and codex neutral (verified items 3 and 1), Fable; panel 3 GLM item 4 for `sp_MSupdate_agenttype_default` (read on the lab); `19-profiles PF.change_default`.

### Profiles across distribution databases

- Expected: a profile belongs to a distribution database.
- Observed (by reading): profiles live in `msdb.dbo.MSagent_profiles` and are shared by every distribution database of the instance, so a profile used through another distribution database reads as unused from one of them.
- Source: by reading, p2 triage item N; `internal/reader/queries.go:361-371`.

### Where sp_add_agent_profile runs

- Expected: in `distribution`, like `sp_update_agent_profile`.
- Observed: it runs from any database, as does `sp_replicationdboption`.
- Source: measured, `12-contexts X.sp_add_agent_profile.*`, `X.sp_replicationdboption.*`.

## Schedules

### What a schedule stores

- Expected: the values passed.
- Observed: `sp_addpublication_snapshot` and `sp_changepublication_snapshot` store `active_end_date` 99991231, `active_end_time` 235959 and `enabled` 1 whatever is passed, zeros included; no replication procedure stores `enabled = 0`. `active_start_date` defaults to the day of the call, so an exported schedule changes at every rebuild of the lab.
- Source: measured, panel 3 Opus, verified item 3 (table of three calls); `11-defaults D.sp_addpublication_snapshot.transactional.@active_*`; panel 3 Fable item 3.

### The start date of sp_changepublication_snapshot

- Expected: a call that omits `@active_start_date` resets the start date to the day of the call, as the creation does.
- Observed: the start date is kept. A schedule created by `sp_addpublication_snapshot @frequency_type = 1, @active_start_date = 99991231` stored start date 99991231, start time 0, end date 99991231, end time 235959 (the end values were not passed). A later `sp_changepublication_snapshot` with a daily type, interval 1, `@frequency_subday = 4`, `@frequency_subday_interval = 10` and the end date and time passed explicitly, but no start date, left the start date at 99991231. The test used a far-future start date, so it shows that the stored value is kept, not what the default would have been on a schedule created with today's date.
- Source: measured, `plan3-fold-review m4` (`sched_created`, `sched_changed_nostart`).

### Changing a schedule's type

- Expected: `sp_changepublication_snapshot @frequency_type` changes the type.
- Observed: alone it is refused with 14278 (a daily schedule needs an interval); with `@frequency_interval` it works. An `@active_end_date` before the start date is refused with 14288.
- Source: measured, `07-changes AGT.sp_changepublication_snapshot.frequency_type`, `.frequency_type+frequency_interval`, `.active_end_date`.

### Two schedules of one name

- Expected: msdb refuses two schedules of the same name on a job.
- Observed: msdb allows it.
- Source: reported by the re-review of plan 2's final fixes (F2), ledger 2 line 89, p2 final-fix-report; the ledger does not say whether it was run.

### An omitted @frequency_subday

- Expected: a daily schedule with `@frequency_subday = NULL` stores no sub-day type, or 0.
- Observed: `sp_addpublication_snapshot` with a daily schedule and `@frequency_subday = NULL` stores `freq_subday_type` 1 (once at the time). `sp_addpushsubscription_agent` with `@frequency_type = 4` and `@frequency_subday = NULL` also stores 1.
- Source: measured, plan 3 task 8 review (2026-11-12).

### Schedule defaults that depend on the frequency

- Expected: an omitted schedule field takes the default of the procedure, 0 for a schedule that starts with the agent.
- Observed: `sp_addpushsubscription_agent` with only `@frequency_type = 4` and `@frequency_interval = 1` stores `freq_subday_type` 4 (minutes), a sub-day interval of 5 and a relative interval of 1, although the defaults of the procedure for an omitted schedule are 0. The defaults of the other schedule fields depend on the frequency.
- Source: measured, plan 3 task 8 review (2026-11-12).

### Fields of start and idle schedules

- Expected: every schedule carries its interval fields.
- Observed: Agent start and idle schedules carry no interval of their own, and one-time schedules usually store `freq_subday_type` 0, which has no meaning.
- Source: `internal/reader/agents.go:137-139`; the comment does not say how it was established.

## Distributor and the linked server

### The distributor linked server

- Expected: the distributor is registered at the publisher under its name.
- Observed (by reading): the linked server is always named `repl_distributor`; the real instance is its `sys.servers.data_source`. `sp_adddistributor` drops an existing `repl_distributor` first.
- Source: by reading `[R] sp_adddistributor.sql:132-154`, `sp_helpdistributor.sql:115-120`; `internal/reader/queries.go:21-24`.

### The provider string of repl_distributor

- Expected: `sys.servers.provider_string` is NULL unless the user set one.
- Observed: `sp_adddistributor` builds it with `sys.fn_getproviderstring`, which returns `Addr=tcp:<server>` whenever the name contains a comma (a distributor added as `<name>,1433` stores `addr=tcp:<name>,1433`), and appends `MultiSubnetFailover=Yes;` when asked. On 2025 the encryption settings go there too.
- Source: by reading the 2022 CU27 definition (controller, p2 triage); the `addr=tcp:` value measured by panel 2 Claude on a 2025 container, verified item 3.

### The 2025 encryption parameters

- Expected: `@encrypt_distributor_connection`, `@trust_distributor_certificate` and `@host_name_in_distributor_certificate` are stored somewhere readable.
- Observed: `sp_adddistributor` passes them to `sys.sp_MSrepl_concat_encryption_params` and appends the result, then `User ID=<login>;`, to the provider string, only when `sys.sp_is_featureswitch_enabled N'ConfigureEncryptionDuringTranReplLinkedServerCreation'` returns 1. Neither helper is visible to `sa`: `OBJECT_ID` is NULL, `sys.all_objects` does not list them, `sp_helptext` has no text, and a direct call is error 2812. `sp_changedistributor_property` finds `Encrypt=`, `TrustServerCertificate=` and `HostNameInCertificate=` with a case-insensitive `PATINDEX`. The sources disagree on whether the written form is measured: `lab/README.md` says it is not (the lab's 2025 distributor has no encryption and a NULL provider string), while panel 2 Claude reports a 2025 container whose distributor, added with `optional` and `yes`, stored `encrypt=optional;trustservercertificate=yes;user id=distributor_admin;`.
- Source: by reading the 2025 definitions, p2 task-13-report, `lab/README.md` "Procedure parameters"; measured, panel 2 Claude, verified item 3; `internal/reader/reader.go:690-696`.

### Where the distributor procedures run

- Expected: all in `master`, or all anywhere.
- Observed: `sp_adddistributor` needs `master` (5001 "User must be in the master database" elsewhere); `sp_adddistributiondb` and `sp_adddistpublisher` run from any database. `sp_adddistributor` fails with 14099 when a distributor exists.
- Also observed: `sp_changedistributiondb` succeeds from `master`, from the publication database and from the distribution database; `sp_changedistpublisher` from `master` and from the publication database. Source: plan 3 task 8 review, measured (2026-11-12).
- Source: measured, `distributor-defaults X.*`; 14099 the panel (design "Order").

### sp_adddistpublisher for a server that does not exist

- Expected: the publisher must exist as a server, or the call is refused.
- Observed: `sp_adddistpublisher` for a server that does not exist succeeds and adds it to `sys.servers`; `sp_dropdistpublisher` removes it.
- Source: measured, plan 3 task 8 review (2026-11-12).

### The snapshot working directory

- Expected: `sp_adddistpublisher` accepts a folder it will create.
- Observed: it refuses a working directory that does not exist (21037). `sp_changedistpublisher working_directory` changes online.
- Source: measured, `lab/README.md` (start.sh note); `07-changes DST.sp_changedistpublisher.working_directory`.

### sp_changedistpublisher security

- Expected: setting `security_mode` back to its value restores the previous state.
- Observed: restoring `security_mode = 1` regenerates the stored publisher password (`MSdistpublishers.password`); `trusted` is refused with 21698, "no longer supported".
- Source: measured, `07-changes DST.sp_changedistpublisher.security_mode`, `.trusted`.

### SQL authentication of the distribution database

- Expected: `sp_adddistributiondb @security_mode = 0` uses defaults for the login.
- Observed: it needs a login (21694), as do the agents' `publisher_security_mode = 0` changes.
- Source: the panel for `sp_adddistributiondb` (design "Secrets"); measured, `07-changes AGT.*.publisher_security_mode`.

### Batch sizes of the distribution cleanup

- Expected: Learn lists every property of `sp_changedistributiondb`.
- Observed (by reading): `deletebatchsize_xact` and `deletebatchsize_cmd` exist (5000 and 2000 on the lab, in `msdb.dbo.MSdistributiondbs` and `sp_helpdistributiondb`) and are not in Learn's list. Changing them is not measured.
- Source: read on the lab, p1 task-6-report item 6.

## System tables and metadata visibility

### Views of the distribution database named like the publisher tables

- Expected: `syspublications`, `sysarticles` and `syssubscriptions` in the distribution database mirror the publishers.
- Observed (by reading): they are views on the `IH*` tables of Oracle publishers. The publisher's tables are read in the publication database only. A procedure run in the wrong database shows it: `sp_articlecolumn` in `distribution` fails with 4406 on the view `dbo.sysarticlecolumns`, `sp_articlefilter` with 20026 ("publication does not exist").
- Source: by reading `[R] sp_MScreate_dist_tables.sql:2102`, `:2153`, `:2214`, `:2342-2350`; measured, `12-contexts X.sp_articlecolumn.distribution`, `X.sp_articlefilter.distribution`.

### Virtual subscribers of syssubscriptions

- Expected: every row of `syssubscriptions` is a subscription.
- Observed (by reading, and seen at the distributor): `srvid` -1 and -2 are virtual subscribers, as are `subscriber_id` -1 and -2 in `MSsubscriptions`; their distribution agents exist and can be bound to a profile.
- Source: by reading `[R] sp_MSadd_subscription.sql:142-143`; measured, p2 task-11-report (the extra query lists the two virtual distribution agents); `internal/reader/queries.go:122-123`, `:368-369`.

### Server name case

- Expected: a server name is stored as `@@SERVERNAME` gives it.
- Observed: `syssubscriptions.srvname` is upper case (`REPLLAB`), `@@SERVERNAME` and `MSreplication_subscriptions.publisher` lower case (`repllab`), and `MSsubscriber_info.publisher` and `subscriber` differ in case from the server names.
- Also observed: `MSsubscriber_info` stores the publisher in upper case (plan 3 task 5 review, measured).
- Source: measured, lab README "Articles and the first measurements"; p2 task-10-report; `internal/reader/queries.go:198-199`.

### MSreplservers and sys.servers

- Expected: `MSreplservers.srvid` is the `sys.servers.server_id` of the server.
- Observed: they differ (1 against 0 on the lab), so a fallback that names servers from `master.sys.servers` resolves every agent to the wrong server. `MSreplservers` exists only from 2016 SP2 CU3 and 2017 CU6 (Learn).
- Source: measured, p2 final-fix.md item 1 and its report; `internal/reader/queries.go:188-192`, `reader.go:394-399`.

### OBJECT_ID and hidden tables

- Expected: `OBJECT_ID(N'dbo.MSreplservers') IS NULL` tells a missing table.
- Observed: `OBJECT_ID` also returns NULL for a table the login cannot see (measured with `DENY SELECT` on `MSreplservers` and `MSpub_identity_range`); a `SELECT` then gives 229 for a denied table and 208 for a missing one, which is the only reliable probe.
- Source: measured, p2 final-fix-report "Measurements made"; `internal/reader/queries.go:98-103`, `:188-192`.

### MSpub_identity_range

- Expected: a replication table present in every published database.
- Observed: it exists only in some databases (in `Sales`, not in `distribution`); its absence is told by error 208.
- Source: measured, p2 task-12-fix-1-report; `internal/reader/queries.go:98-103`.

### DB_ID without VIEW ANY DATABASE

- Expected: `DB_ID(N'x')` is NULL only for a missing database.
- Observed: for a login denied `VIEW ANY DATABASE`, `DB_ID`, `HAS_DBACCESS` and the `sys.databases` row are NULL or absent for an existing database too.
- Source: measured with a temporary login, p2 task-10-report item C; `internal/reader/queries.go:413-419`.

### Filter procedure and source names under db_datareader

- Expected: `OBJECT_NAME(sysarticles.filter)` names the filter procedure for any reader of `sysarticles`.
- Observed: under `db_datareader` it is NULL while `filter` holds the id (1893581784 for `SalesPub.Customer`). The source object of a schema-only article is hidden the same way. `VIEW DEFINITION` on the publication database is enough to see the filter procedure and the synchronization view definition.
- Source: measured, p2 final-fix-report items 4 and 12 and the residual docs note; `internal/reader/publisher.go:233-235`.

### The distribution database files

- Expected: `sys.master_files` lists the files of the distribution database.
- Observed: it is empty for a login without the permission to see them.
- Source: measured with `m_probe`, p2 final-fix-report "Measurements made".

### Hidden replication procedures

- Expected: `sa` can read the definition of any system procedure.
- Observed: `sys.sp_MSrepl_helparticle` has no readable definition (`OBJECT_DEFINITION` NULL) on 2022, and on 2025 `sys.sp_MSrepl_concat_encryption_params` and `sys.sp_is_featureswitch_enabled` are not even listed in `sys.all_objects`; calling the latter is 2812. The public procedures (`sp_changearticle`, `sp_addarticle`, `sp_help*`) are wrappers around `sys.sp_MSrepl_*`, whose code is not in the 2019 sources either, so the invalidation rules cannot be read.
- Source: measured, p2 task-12-fix-1-report, p2 task-13-report; analysis section 2.

### sys.dm_os_file_exists on a folder

- Expected: `file_exists` 1 for an existing folder.
- Observed: `file_exists 0, file_is_a_directory 1` for the snapshot working directory.
- Source: measured, panel 3 Opus, "Not a problem".

## Permissions

### The linked server under a low login

- Expected: a login that can read the publication database sees the distributor link.
- Observed: without `ALTER ANY LINKED SERVER`, `sys.servers.provider_string` of `repl_distributor` is NULL whatever it holds (so `MultiSubnetFailover` and the 2025 keys cannot be read), and under `db_datareader` alone `sys.linked_logins` is empty too; `VIEW ANY DEFINITION` shows `sys.linked_logins` but not the provider string.
- Source: measured, p2 final-fix-report item 3 and residual docs note; `internal/reader/queries.go:34-40`, `reader.go:643-647`.

### Wait information

- Expected: a login without `VIEW SERVER PERFORMANCE STATE` gets an error on the wait DMVs.
- Observed: `sys.dm_os_waiting_tasks` fails with error 300, while `sys.dm_exec_requests` raises no error and returns the caller's own session only, so a missing permission looks like an idle server. Before 2022 the permission is `VIEW SERVER STATE`.
- Source: measured, `16-snapshot-report-sources RS.m_low.waiting_tasks`, `RS.m_low.exec_requests`.

### The snapshot folder through the DMV

- Expected: listing the snapshot folder needs `sysadmin`.
- Observed: `sys.dm_os_enumerate_filesystem` lists the run folder as `find` does for a login with only `public` at the server and `SELECT` in `distribution`.
- Source: measured, `16-snapshot-report-sources RS.*.filesystem_low`.

## Versions

### Parameters by version

- Expected: the creation procedures have the same parameters on 2019, 2022 and 2025.
- Observed: 2019 CU32 lists 307 parameters, 2022 CU27 316, 2025 CU10 319. 2022 adds nine: `sp_adddistributor @security_mode` and `@multi_subnet_failover`, `@job_security_mode` of the four agent procedures, and `sp_addsubscription @subscriber_security_mode`, `@subscriber_login`, `@subscriber_password`. 2025 adds three encryption parameters to `sp_adddistributor`, placed before `@multi_subnet_failover`. `sys.all_parameters.max_length` is in bytes: they list as `nvarchar(20)`, `nvarchar(20)`, `nvarchar(510)` for a declared `nvarchar(10)`, `nvarchar(10)`, `nvarchar(255)`.
- Source: measured, `lab/results/2019/17-parameters.txt`, `lab/results/2022/17-parameters.txt`, `lab/results/2025/17-parameters.txt`; p2 task-13-report; panel 2 Mistral.

### The version of a Managed Instance

- Expected: `SERVERPROPERTY('ProductVersion')` tells which tables a distributor has.
- Observed (not measured): a Managed Instance with the current engine reports 12.0.2000.8, so a version cut would take it for SQL Server 2014.
- Source: from the re-review of plan 2's final fixes (F3), ledger 2 line 89; `internal/reader/reader.go:397-399`. No Managed Instance was at hand.

### What is measured on which version

- Expected: the behaviors above hold on 2019 and 2025.
- Observed: only `17-parameters` has run on 2019 and 2025, plus the review seats' own containers (panel 2 Claude and Mistral on 2019 and 2025). The implicit push job (`O13`) and the anonymous pull subscription (`08-pull P1.omitted`) are 2022 measurements, and the 2019 source differs on the second (20016).
- Source: `lab/README.md` "The campaign" and "Procedure parameters".

## Error handling and transactions

### A refused call and its transaction

- Expected: a refused replication procedure rolls back what it opened.
- Observed: it leaves its transaction open: `@@TRANCOUNT = 1` in the `CATCH` of a refused `sp_addarticle`, two levels after a refused `sp_droparticle`, 2 after `sp_changepublication replicate_ddl = N'false'` (245), 1 after `sp_changearticle schema_option` given a binary literal (21805). What follows runs in it and is lost when the session ends. The transaction may also be doomed (`XACT_STATE() <> 1`), so the state read after it is not the state of the case.
- Also observed: the count adds up: `@@TRANCOUNT` reads 3 after `sp_dropsubscription` followed by `sp_droparticle` (whether both were refused is not recorded in the ledger line); a refusal by 20640 leaves it unchanged; and `@@ERROR` is 0 right after the refused `EXEC`, so it cannot be used to detect the refusal. Source: plan 3 task 7 review, measured.
- Also observed: not every refusal leaves the transaction open. `sp_changepublication allow_pull N'false'` on a publication with subscriptions is refused with 20013 and leaves `@@TRANCOUNT` at 1; `sp_changearticle ins_cmd N'XCALL ...'` is refused with 15251 and leaves it at 0; `sp_changearticle sync_object` with an unqualified view name outside `dbo` fails with 15001 and leaves it at 1. Source: plan 3 task 8 review, measured (2026-11-12).
- Source: measured, lab row 11 (`03-add-article C3`); the panel for `sp_droparticle` (design "apply" step 4); panel 3 Mistral, verified items 1 and 2; `lab/campaign/14-filter-view-cases.sql:141-143`.

### The @value of sp_changearticle and sp_changepublication

- Expected: `@value` takes the literal of the property's type, and booleans accept `N'true'` and `N'false'`.
- Observed: `sp_changearticle @property = 'schema_option'` needs the string `N'0x0000000000030073'`; the binary literal `0x0000000000030073` is refused with 21805 ("'' is not a valid value for the '@value' parameter. The value must be an integer"). `sp_changepublication replicate_ddl` refuses `N'false'` with 245 (conversion to int) and accepts `N'0'` and `N'1'`, while every other boolean property accepts `N'true'` and `N'false'`. `sp_addarticle @schema_option` is `binary(8)` and takes the bare literal.
- Also observed: the creation procedure has the opposite type. `sp_addpublication @replicate_ddl = N'false'` fails client-side with 8114 ("Error converting data type nvarchar to int", HResult 0x1FB2), the return code NULL: the parameter is `int(4)` at creation, while `sp_changepublication @property = N'replicate_ddl'` takes `N'0'` or `N'1'`. `@replicate_ddl = 0` at creation succeeds.
- Source: measured, panel 3 Mistral, verified items 1 and 2; plan 3 rule R39; the creation case plan 3 task 8 review, measured (2026-11-12).

### Message 18752 during drops

- Expected: dropping a publication either succeeds or fails.
- Observed: the drop of the last publication of a database, which drops its log reader, can print Msg 18752 ("only one Log Reader Agent or log-related procedure") once or twice from `sys.sp_replcmds` while the log reader runs, and still complete: return code 0, `@@TRANCOUNT` 0, publication and log reader gone. Of eight publications of one database dropped in turn, only the last raised it. Under load it came with the log reader blocked for over 200 s. Ten idle create and drop cycles of `13-transient` saw none. It was also seen during `sp_replicationdboption @value = N'false'`. Dropping the last publication with no subscription left prints no 18752 in one attempt (`06-structural C5`). On 2019 and 2025 not measured.
- Source: measured, `O14` (Claude, controller, fix review), `O21`, panel 3 Opus; `13-transient T01` to `T10`; `06-structural C5.*`.

### Deadlock during subscription drops

- Expected: no deadlock between replication procedures run one at a time.
- Observed: the panel met a 1205 during a sequence of subscription drops; ten cycles of `13-transient` on an idle lab did not reproduce it. Whether a retry is safe is open.
- Source: the panel (design "apply"); `13-transient`.

### Errors from the wrong database

- Expected: a procedure run in the wrong database says so in one way.
- Observed: the messages differ by procedure: 14013 "This database is not enabled for publication" for most, 208 "Invalid object name 'syspublications'" for `sp_articlefilter` and `sp_articleview` in `master` or `msdb`, 18757 for `sp_addpublication_snapshot`, 21481 for `sp_addpullsubscription` in `master`, 21831 for a second `sp_addlogreader_agent` in a published database. Push subscription procedures fail in the distribution database with 14013.
- Source: measured, `12-contexts X.*`; the panel for push procedures in `distribution` (design "Subscriptions").

### Generic and inner errors

- Expected: each refusal has its own error number.
- Observed: some refusals come as error 50000 (`@job_login must be a non-null/non-empty value`), some from an inner procedure (14043 from `sp_MSrepl_addsubscriber`, 20026 from `sys.sp_MSreinit_article` after 14027), and the agents' failures as 14151, "agent ... failed", whose cause is elsewhere (see "The error of a history row").
- Source: measured, `07-changes AGT.*.job_password`; panel 2 Claude item 7; panel 3 GLM item 1; `10-init-modes I2.backup.gap-original`.

## Where Microsoft Learn disagrees with the lab

Each entry names the Learn page, says what it says (as recorded in the sources; Learn was read on 2026-11-10 for the analysis and the campaign) and what was measured. The sources record page names, not URLs. Nothing has been filed with Microsoft yet.

### sp_addarticle

- Learn: the default `schema_option` of a table article is `0x30F3`.
- Measured: `0x30073`; `0x80` is not set.
- Rows: `01-articles A2`; `11-defaults D.sp_addarticle.table.native.@schema_option`.

### sysschemaarticles

- Learn: `pre_creation_cmd` 1 = Delete, 2 = Drop, the reverse of `sysarticles`.
- Measured: the default `drop` is stored as 1, the same code as `sysarticles`.
- Rows: `01-articles A8`.

### sp_articlecolumn

- Learn: a column filter can only be changed on an unsubscribed article.
- Measured: accepted on a subscribed article, with the flags of the matrix (snapshot and reinitialization on `immediate_sync`, reinitialization otherwise).
- Rows: `02-matrix F04` to `F06`; `14-filter-view F6s`.

### sp_changearticle

- Learn: changing `ins_cmd`, `upd_cmd` or `del_cmd` needs a new snapshot and a reinitialization; `pre_creation_cmd` and `schema_option` need a new snapshot only; and the page disagrees with another Learn page on `status` (the sources do not name the second page).
- Measured: the commands change online on a transactional publication (a reinitialization on a snapshot publication); `pre_creation_cmd` and `schema_option` also need a reinitialization; `include column names` and `string literals` change online.
- Rows: `02-matrix A06` to `A09`, `A10` to `A13`, `A14` to `A16`; `09-snapshot-pub TWIN.A01` to `A04`, `SNAP.A06` to `A09`.

### sp_changepublication

- Learn: a `sync_method` change needs a new snapshot only; `pre_snapshot_script` and `post_snapshot_script` need a reinitialization; the flags of most other properties are not documented.
- Measured: a change from or to `concurrent` or `concurrent_c` needs a reinitialization and marks every subscription, one between `native`, `character` and `database snapshot` marks nothing; the scripts need the snapshot flag only, on a ready `immediate_sync` snapshot, and are online otherwise.
- Rows: `02-matrix P21`, `P22`, `P33` to `P35`; `15-snapshot-scope C.*.sync_method`, `D.*.sync_method_probe`.

### sp_changesubscriber

- Learn: "Any distribution task for the Subscribers to this Publisher is updated."
- Measured: no job, job step, schedule or agent row changes; only `MSsubscriber_info` and `MSsubscriber_schedule`.
- Rows: `07-changes SBR.*`.

### sp_change_subscription_properties

- Learn: a NULL `dts_package_password` leaves the password unchanged; the page lists 28 properties.
- Measured: a NULL `dts_package_password` is refused with 21732; `distributor` and `memory_optimized` are accepted though not listed.
- Rows: `08-pull P2.dts_package_password`, `P2.distributor`, `P2.memory_optimized`.

### sp_adddistributor

- Learn: `@trust_distributor_certificate` is `nvarchar(5)`; `@encrypt_distributor_connection` "can't be NULL"; `@multi_subnet_failover` applies from SQL Server 2025 CU8.
- Measured: the 2025 definition declares `@trust_distributor_certificate` `nvarchar(10)` and defaults `@encrypt_distributor_connection` to NULL; 2022 CU27 already has `@multi_subnet_failover`.
- Rows: `lab/results/2025/17-parameters.txt`, `lab/results/2022/17-parameters.txt`; p2 task-13-report, concern 2.

### sp_changepublication_snapshot

- Learn: `snapshot_job_name` is "the name of an existing job if an existing job is used".
- Measured: the call is accepted, the job keeps its name, and its `sysjobs` row is bumped. Whether this contradicts the page or is the page's meaning is not clear from the sources.
- Rows: `07-changes AGT.sp_changepublication_snapshot.snapshot_job_name`.

### sp_changedistributiondb

- Learn: the list of properties.
- Read on the lab: `deletebatchsize_xact` and `deletebatchsize_cmd` exist and are not in the list. By reading, not measured.
- Rows: none; p1 task-6-report item 6.

### syspublications

- Learn: `sync_method` 0, 1, 3, 4; the `options` bits 0x1, 0x2, 0x4, 0x8, 0x100.
- Measured: `sync_method` 5 (`database snapshot`) and 6 (`database snapshot character`); `options` 0x20 (`allow_partition_switch`) and 0x40 (`replicate_partition_switch`); 0x80 (`allow_drop`) by reading. Omissions rather than errors.
- Rows: plan 2 "Rulings made in this plan"; panel 2 Mistral; `[R] sp_MScheck_dropobject.sql:25-29`.

### sysarticles

- Learn: `status` bits 1, 8, 16.
- Measured: bit 0x20 is set with 0x8 when `schema_option` has 0x8. An omission.
- Rows: `01-articles A3`.

### sp_dropsubscription

- Learn (Remarks, as the analysis records it): the subscription to one article of an `immediate_sync` publication cannot be added back unless the subscriptions to all articles are dropped and re-added at once.
- Measured: `sp_addsubscription @article = N'all'` adds it back, accepted, at status 2 with nothing delivered: the rows changed in the gap are lost silently.
- Rows: panel 3 Opus, verified item 1 (no campaign row).

## Error numbers

The numbers met, with their meaning in this context. The agent messages met in the history (14151, 21021, 21084) are listed with the procedure errors.

| Error | Where | Meaning here |
|---|---|---|
| 201 | `sp_addpullsubscription_agent` | a required parameter (`@publisher_db`, `@publication`) not passed |
| 208 | a `SELECT`, `sp_articlefilter` in `master` | the table does not exist (the reliable absence probe); `syspublications` not found outside a publication database |
| 229 | a `SELECT` | the login is denied the table, which `OBJECT_ID` hides as NULL |
| 245 | `sp_changepublication replicate_ddl` | `N'false'` converted to int; leaves the transaction open |
| 300 | `sys.dm_os_waiting_tasks` | `VIEW SERVER PERFORMANCE STATE` missing |
| 1205 | subscription drops | deadlock, met once by the panel, not reproduced |
| 2627 | inside 14151 | primary key violation when a re-add replays delivered rows |
| 2812 | 2025 hidden helpers | the procedure cannot be found, though `sp_adddistributor` calls it |
| 3217 | `sp_change_subscription_properties` | invalid property (`publisher_*`, `subscriber_*`, `dynamic_snapshot_location`, an unknown name) |
| 3624 | `sp_changearticle filter` | engine assertion, severity 20, connection ended |
| 4406 | `sp_articlecolumn` in `distribution` | update of the Oracle view `sysarticlecolumns` |
| 5001 | `sp_adddistributor` | must run in `master` |
| 8114 | `sp_addpublication @replicate_ddl = N'false'` | conversion of nvarchar to int, client-side; the parameter is int at creation |
| 14005 | `sp_droppublication` | subscriptions remain |
| 14013 | publication procedures | the current database is not enabled for publication |
| 14027 | `sp_addarticle @filter` | the filter procedure does not exist yet |
| 14041 | `sp_changesubscription` | heterogeneous property on a publication not enabled for it |
| 14043 | `sp_articlefilter`, `sp_dropsubscription`, `sp_addsubscription` | a NULL parameter (`@filter_name`, `@article`, `@subscriber`) |
| 14046 | `sp_droparticle` | the article is subscribed |
| 14049 | `sp_changearticle filter` | a plain procedure, not a replication filter |
| 14058 | `sp_addsubscription` | the subscription already exists (an extension on `immediate_sync`) |
| 14070 | `sp_articlefilter` | after 21861, during a snapshot run |
| 14080 | `sp_change*` `publisher` | the remote server is not a valid publisher |
| 14088 | `sp_addarticle` | a transactional table article without a primary key |
| 14099 | `sp_adddistributor` | a distributor exists |
| 14100 | `sp_addsubscription` | a named article on a `concurrent` or `concurrent_c` publication |
| 14122 | `sp_addsubscription` | a named article on an `immediate_sync` publication under `native` or `character` |
| 14124 | `sp_addsubscription` | refused (no article); leaves the subscriber registered |
| 14151 | distribution agent | "agent ... failed", the wrapper of an agent failure |
| 14262 | `msdb.dbo.sp_update_job` | the `@job_id` names no job (a snapshot agent never added) |
| 14278 | `sp_changepublication_snapshot` | `frequency_type` without the interval it needs |
| 14288 | `sp_changepublication_snapshot` | end date before start date |
| 14529 | `job_login` changes | not a valid Windows account |
| 15001 | `sp_changearticle sync_object` | the unqualified name of a view outside `dbo`; leaves `@@TRANCOUNT` at 1 |
| 15002 | `sp_addsubscription` | cannot run inside a transaction |
| 15251 | `sp_addarticle`, `sp_changearticle` | `upd_cmd = 'SCALL'` without a procedure name; `ins_cmd N'XCALL ...'` (leaves `@@TRANCOUNT` at 0) |
| 18752 | publication drops | another log reader or log-related procedure; the drop may still complete |
| 18757 | `sp_addpublication_snapshot` | the database is not published |
| 18787 | `sp_changepublication` | initialization from backup on a snapshot publication |
| 20011 | `sp_changepublication` | `allow_anonymous` without `immediate_sync` |
| 20012 | `sp_changepublication`, `sp_addsubscription` | `allow_push` or `allow_pull` needed or refused, message with `(null)` |
| 20013 | `sp_changepublication` | `independent_agent` or `allow_pull = false` changed while subscriptions exist |
| 20016 | `sp_addpullsubscription` (2019 source) | pull without `@subscription_type`, by reading |
| 20017 | `sp_addpullsubscription_agent` | the subscription does not exist at the subscriber |
| 20026 | `sp_articlefilter` in `distribution`, inside 14027 | the publication does not exist |
| 20067 | `sp_add_agent_parameter` | the parameter exists (copied from the default profile) |
| 20607 | `sp_change*`, `sp_addarticle`, `sp_droparticle` | needs `@force_invalidate_snapshot = 1` (ready `immediate_sync` snapshot) |
| 20608 | `sp_change*` | needs `@force_reinit_subscription = 1` (a row at status 2) |
| 20640 | `sp_changepublication` | `enabled_for_het_sub` while subscriptions exist |
| 21000 | `sp_addsubscription` | subscription on an inactive publication |
| 21021 | pull agent message | the subscription does not exist (publisher dropped first) |
| 21022 | `sp_addpublication`, `sp_changepublication` | `immediate_sync` without `independent_agent` |
| 21023 | `sp_changearticle status` | `owner qualified` no longer supported |
| 21037 | `sp_adddistpublisher` | the working directory does not exist |
| 21084 | pull agent | the publication does not allow anonymous subscriptions |
| 21157 | `sp_changepublication` | `compress_snapshot` without `alt_snapshot_folder` |
| 21158 | `sp_changepublication` | `enabled_for_internet` without `ftp_address` |
| 21183 | `sp_change_agent_profile`, `sp_changesubscription` | invalid property name |
| 21193 | `sp_addarticle` | `auto` identity range without the range parameters |
| 21210 | `sp_changepublication` | `allow_subscription_copy` without `immediate_sync` |
| 21231 | `sp_addarticle` | `auto` identity range without updating subscribers |
| 21481 | `sp_addpullsubscription` | in `master` |
| 21482 | `msdb.dbo.sp_update_agent_profile` | not run in the distribution database |
| 21678 | `sp_addpublication` | `replicate_partition_switch` without `allow_partition_switch` |
| 21694 | `sp_adddistributiondb`, agent changes | security mode 0 without a login |
| 21698 | `sp_changedistpublisher`, `sp_change_subscription_properties` | `trusted`, `offload_agent`, `offload_server` no longer supported |
| 21732 | `sp_change_subscription_properties` | NULL `dts_package_password` |
| 21805 | `sp_changearticle` | `@value` not valid (a binary literal for `schema_option`) |
| 21830 | `sp_addarticle` | schema option 0x4 with identity range management NONE |
| 21831 | `sp_addlogreader_agent` | the log reader already exists |
| 21854 | `sp_addarticle` | a snapshot is being generated |
| 21861 | `sp_articlefilter` | would deactivate an article while a snapshot is generated |
| 21866 | `sp_changepublication` | `replicate_partition_switch` without `allow_partition_switch` |
| 22547 | `sp_changepublication`, creation | `concurrent` on a snapshot publication |
| 41989 | agent changes | `@job_security_mode` is Managed Instance only |
| 50000 | `job_password` changes | generic `RAISERROR`: `@job_login` must be non-null |
| HResult 0x5606 | `sp_startpublication_snapshot` | the job is already running; informational line, not an error |
