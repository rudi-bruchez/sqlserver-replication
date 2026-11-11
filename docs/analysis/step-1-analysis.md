# Step 1 analysis

Todoist task: "Declarative configuration layer for SQL Server transactional replication: analysis then implementation". Language chosen on 2026-11-10: Go.

Source legend:

- [L] Microsoft Learn, read on 2026-11-10;
- [R] SQL Server 2019 system procedure source in this repository (`stored-procedures/`);
- [I] inference, to be checked;
- [M] to be measured on an instance;
- [X] measured on SQL Server 2022 CU27: `lab/README.md`, and the campaign results `lab/results/2022/<script>.txt`, cited as `<script> <case id>` (for example `05-snapshot-flag S7.O1`).

## 1. Scope

Transactional replication, push subscriptions, SQL Server publisher. Out of scope: merge, peer-to-peer, updatable subscriptions (immediate or queued), pull and anonymous subscriptions, Oracle publishers.

## 2. What this repository provides, and what it does not

The public procedures (`sp_addarticle`, `sp_changearticle`, `sp_changepublication`, `sp_helparticle`, `sp_helppublication`, `sp_helpsubscription`…) are only wrappers. They call `sys.sp_MSrepl_<name>` (for instance `sp_changearticle.sql:37`), and those implementations are not in the repository. The rule that decides whether a change invalidates the snapshot or reinitializes a subscription cannot be read here.

The repository is useful for reading state, though. The distributor-side procedures are real queries and show the right joins:

- `sp_MShelpsnapshot_agent.sql:55-68`: agent, job, step, proxy, credential, schedule;
- `sp_MShelp_subscription.sql:30-43`: name resolution through `MSreplservers`, exclusion of virtual subscriptions;
- `sp_MSenumdistributionagentproperties.sql`: distribution agent, with the warning that `job_id` can outlive a deleted job (:78-93);
- `sp_MShelp_profile.sql:57-108`: effective profile of an agent.

The impact matrix (section 5) therefore comes from Learn. Learn contradicts itself in several places, so the matrix has to be measured.

## 3. Where the state lives

### Publisher, publication database

| Object | Content | Notes |
|---|---|---|
| `syspublications` | one row per publication | `snapshot_jobid` points to the snapshot job; `options` is a bitmask (section 4) |
| `sysarticles` | table articles | resolve `objid` through `sys.objects` / `sys.schemas`; `filter` is the filter procedure id, `filter_clause` the text |
| `sysschemaarticles` | schema-only articles (procedure, view, function) | |
| `sysextendedarticlesview` | union of the two above | [R] `sp_MScreate_dist_tables.sql:2342-2350`; convenient to list every article |
| `sysarticlecolumns` | published columns (vertical filter) | `colid` = `sys.columns.column_id` [I] |
| `syssubscriptions` | one row per article and per subscriber | filter `srvid >= 0`: -1 and -2 are virtual subscribers [R] `sp_MSadd_subscription.sql:142-143` |

Trap [R]: `sp_MScreate_dist_tables.sql` creates views named `syspublications`, `sysarticles`, `syssubscriptions`… in the `distribution` database, on top of the `IH*` tables used by Oracle publishers (:2153, :2214, :2102). These objects must be read in the publication database, never in `distribution`.

### Distributor, `distribution` database

| Object | Content | Notes |
|---|---|---|
| `MSreplservers` | `srvid` → `srvname` | resolves `publisher_id` and `subscriber_id` (since 2016 SP2 CU3 / 2017 CU6) [L] |
| `MSpublications`, `MSarticles` | partial mirrors of the publisher | use for consistency checks, not as a source |
| `MSsubscriptions` | one row per subscribed article | ignore `subscriber_id < 0`; `agent_id` → `MSdistribution_agents.id` |
| `MSlogreader_agents` | one agent per published database | publisher connection security, `profile_id`, `job_id` |
| `MSsnapshot_agents` | one agent per publication | same |
| `MSdistribution_agents` | one agent per subscription (or shared) | `publication = N'ALL'` for a shared agent [R]; `subscriptionstreams`, `subscriber_security_mode`, `subscriber_login` |

### Distributor, `msdb`

| Object | Content |
|---|---|
| `MSdistributiondbs` | `min_distretention`, `max_distretention`, `history_retention` |
| `MSdistpublishers` | authorized publishers: `distribution_db`, `working_directory`, `security_mode`, `login`, `trusted` |
| `MSdistributor` | key/value; only property seen in the repository: `heartbeat_interval` [R] |
| `MSagent_profiles`, `MSagent_parameters` | profiles (`type = 1`: user-defined) and their parameters |
| `sysjobs`, `sysjobsteps`, `sysjobschedules`, `sysschedules` | agent jobs; `job_id` is `binary(16)` in `distribution` and must be converted to `uniqueidentifier` [R] `sp_MShelpsnapshot_agent.sql:57` |

The agent command line (`sysjobsteps.command`) can override the profile. It belongs to the state to export [I].

### Subscriber

`MSreplication_subscriptions` is written by the distribution agent. It is a witness, not a configuration source: it shows that a subscription does exist at the subscriber.

## 4. Decoding

All from [L] unless stated otherwise.

`syspublications`

| Column | Values |
|---|---|
| `repl_freq` | 0 = transactional, 1 = snapshot |
| `sync_method` | 0 = native, 1 = character, 3 = concurrent, 4 = concurrent_c (2 is not documented) |
| `status` | 0 = inactive, 1 = active |
| `independent_agent`, `immediate_sync`, `allow_*`, `replicate_ddl` | booleans |
| `retention` | hours |

`options` bits:

| Bit | Meaning | Source |
|---|---|---|
| 0x1 | P2P | [L] |
| 0x2 | P2P, local changes only | [L] |
| 0x4 | non-SQL Server subscribers | [L] |
| 0x8 | P2P conflict detection | [L] |
| 0x80 | `@OPT_ALLOW_DROP`, i.e. the `allow_drop` property | [R] `sp_MScheck_dropobject.sql:25-29` |
| 0x100 | last writer wins | [L] |

`sysarticles`

| Column | Values |
|---|---|
| `type` | 1 = logbased; 3 = + manual filter; 5 = + manual view; 7 = both; 8 = proc exec; 24 = serializable proc exec; 32, 64, 128 = schema-only procedure, view, function |
| `status` (bitmask) | 1 = active; 8 = column names in INSERT; 16 = parameterized commands; 32 = undocumented, set with 8 when `schema_option` has `0x8` [X] |
| `pre_creation_cmd` | 0 = none, 1 = DROP, 2 = DELETE, 3 = TRUNCATE |
| `schema_option` | `binary(8)`, read as a big-endian `uint64` [I]; 44 bits documented on the `sp_changearticle` page; default `0x30F3` for a table article per Learn, `0x30073` measured [X] |
| `ins_cmd`, `del_cmd` | `CALL`, `XCALL` (del), `SQL`, `NONE` |
| `upd_cmd` | `CALL`, `MCALL`, `SCALL`, `XCALL`, `SQL`, `NONE` |

`ins_cmd`, `upd_cmd` and `del_cmd` are stored as text, together with the procedure name (`CALL [sp_MSins_dboT]`). The declarative file should split the mode (`CALL`) from the procedure name, and carry the name only when it differs from the generated one [I].

For `sysschemaarticles.pre_creation_cmd`, Learn gives 1 = Delete and 2 = Drop, the reverse of `sysarticles`. Measured: the default `drop` is stored as 1, the same code as `sysarticles` [X].

The article `type` does not say whether the filter procedure or the synchronization view was named by the user [X]: `sp_articlefilter` requires `@filter_name` and keeps type 1, and `sp_articleview @view_name` too. A generated synchronization view is named `syncobj_0x<hex>`. The stored commands are schema-qualified on 2022 (`CALL [dbo].[sp_MSins_dboT]`), and `upd_cmd = 'SCALL'` without a procedure name is refused (error 15251) [X].

`syssubscriptions`

| Column | Values |
|---|---|
| `subscription_type` | 0 = push, 1 = pull |
| `sync_type` | 1 = automatic, 2 = none |
| `nosync_type` | 0 = snapshot, 1 = replication support only, 2 = backup, 3 = LSN |
| `status` | 0 = inactive, 1 = subscribed, 2 = active; runtime state, not configuration |

## 5. Impact matrix

This matrix matters because of how the procedures behave. A `sp_change*` call with `@force_invalidate_snapshot = 0` and `@force_reinit_subscription = 0` fails without changing anything when the change requires either flag [L]. The plan must know in advance which flags to pass, and say so.

The tables below are measured [X] by `lab/campaign/02-matrix.sql` (results `02-matrix`, cases `P01` to `F06`), on SQL Server 2022 CU27, 2026-11-10, and completed by the campaign scripts named in each row. Each case runs four times, once per combination of the two flags, inside a transaction that is rolled back, from the same state: snapshot delivered, push subscription active. Two publications are measured, because the result depends on `immediate_sync`:

- `SalesPub`: `immediate_sync = 1` (`immediate_sync_ready = 1`), independent agent;
- `SalesRef`: `immediate_sync = 0`, shared agent.

The procedures raise two errors: 20607 asks for `@force_invalidate_snapshot = 1`, 20608 for `@force_reinit_subscription = 1`. Only `SalesPub` ever raised 20607. On `SalesRef`, a change that only affects the snapshot is accepted with no flag, and a change that needs a reinitialization needs that flag alone.

The two conditions are separated by `05-snapshot-flag`, which runs nine operations in seven snapshot states [X]. 20607 is raised exactly when `immediate_sync_ready = 1` (states `S1` and `S7`), never on an `immediate_sync` publication whose snapshot was never generated (`S2`) or was invalidated (`S5`, `S6`): snapshot files on disk do not matter. 20608 is raised when the subscription to the operated article is at status 2 (`S3.O3`, `S5.O3`), not when it is at status 1 (`S4`, `S6.O3`, `S6.O7` to `S6.O9`); for `sync_method`, which concerns every article, when any article is at status 2 (`S6.O6`). A subscription added to an `immediate_sync` publication with a ready snapshot is at status 2 at once, before any delivery (`S7`), so it asks for both flags like a delivered one.

Checked outside a transaction for one accepted case (`ins_cmd`) and one refused case (`pre_creation_cmd`): same result.

Legend: "snapshot" = needs `@force_invalidate_snapshot = 1`; "reinit" = needs `@force_reinit_subscription = 1`; "online" = accepted with both flags at 0; "refused" = no flag combination is accepted, the error says why.

### Publication properties (`sp_changepublication`)

| Property | `immediate_sync = 1` | `immediate_sync = 0` | Learn said |
|---|---|---|---|
| `description`, `retention`, `replicate_ddl`, `allow_pull`, `allow_initialize_from_backup`, `allow_partition_switch`, `allow_drop`, `status` | online | online | not documented |
| `sync_method`, from or to `concurrent` or `concurrent_c` (between those two included) | snapshot + reinit, every subscription marked | reinit, every subscription marked | snapshot only |
| `sync_method` between `native`, `character` and `database snapshot` | snapshot, nothing marked | online | snapshot only |
| `alt_snapshot_folder`, `snapshot_in_defaultfolder`, `pre_snapshot_script`, `post_snapshot_script`, `ftp_address` | snapshot | online | snapshot; reinit for the scripts |
| `compress_snapshot` | refused while no `alt_snapshot_folder` (21157) | | snapshot |
| `enabled_for_internet` | refused while `ftp_address` is null (21158) | | snapshot |
| `enabled_for_het_sub` | refused while subscriptions exist (20640) | | snapshot, and the same restriction |
| `allow_push = false` | refused while push subscriptions exist (20012, with `(null)` in the message) | | not documented |
| `allow_subscription_copy = true` | online | refused, needs `immediate_sync` (21210) | not documented |
| `replicate_partition_switch = true` | refused while `allow_partition_switch` is false (21866) | | not documented |
| `immediate_sync` | `false`: online, but a ready snapshot is dropped (`immediate_sync_ready` 1 to 0, nothing marked, `15-snapshot-scope` `B.*_noanon.1b`) | `true`: refused while `independent_agent` is false (21022) | not documented |
| `independent_agent` | `false`: refused while `immediate_sync` is true (21022) | `true`: refused while subscriptions exist (20013) | not documented |
| `allow_anonymous = true` | online | refused while `immediate_sync` is false (20011) | not documented |
| `allow_anonymous = false` | online, but a ready snapshot is dropped (`immediate_sync_ready` 1 to 0, nothing marked, `15-snapshot-scope` `B.*_anon.1a`) | | not documented |

Consequences for the plan:

- The dependency chain of Learn is confirmed: `allow_anonymous` needs `immediate_sync`, which needs `independent_agent`. Disabling goes from the top down, each step online in the sense of the legend (no flag). The first of `allow_anonymous = false` and `immediate_sync = false` still drops a ready snapshot without marking anything, so the plan reports it with a cost of its own (design, "Publication properties").
- `independent_agent` cannot change while the publication has subscriptions, in either direction. Enabling `immediate_sync` on a shared-agent publication with subscriptions therefore means dropping the subscriptions, changing `independent_agent`, then `immediate_sync`, and adding the subscriptions back, which reinitializes them. The plan must show it as such, not as two property changes.
- `alt_snapshot_folder` must be set before `compress_snapshot`, `ftp_address` before `enabled_for_internet`, `allow_partition_switch` before `replicate_partition_switch`.
- `sync_method` costs depend on the source and the target (`15-snapshot-scope`, rows `C.*.sync_method` and `D.*.sync_method_probe`, `D.*_pub.change`; `02-matrix` `P21`, `P22`). Measured pairs: `native` to `character` (`D.non_native.sync_method_probe` f00, `D.imm_native.sync_method_probe` f10), `character` to `native` and `database snapshot` to `native` (`C.character.sync_method`, `C.dbsnap.sync_method`, f10 on `immediate_sync`), all marking nothing; `native` to `concurrent`, `concurrent` and `concurrent_c` to `native`, `concurrent` to `concurrent_c` and back (`C.native`, `C.concurrent`, `C.concurrent_c`, `D.non_concurrent.sync_method_probe`, `D.*_pub.change`, `D.*_pub.extend_then_change`), all needing the reinit flag and setting every subscription row to status 1. Not measured on a transactional publication: `native` or `character` to `database snapshot`, and anything involving `database snapshot character`. On a snapshot publication, `native` to `character` and to `database snapshot` change online, or with the snapshot flag when the snapshot is ready, and `concurrent` is refused with 22547 (`09-snapshot-pub` `SNAP.P12` to `P14`, `SNAPI.P12` to `P14`).
- `working_directory` (`sp_changedistpublisher`) changes online (`07-changes` `DST.sp_changedistpublisher.working_directory`).

### Article properties (`sp_changearticle` and related procedures)

| Property or operation | `immediate_sync = 1` | `immediate_sync = 0` | Learn said |
|---|---|---|---|
| `description`, `ins_cmd`, `upd_cmd`, `del_cmd`, `fire_triggers_on_snapshot` | online | online | commands: snapshot + reinit |
| `status` (`include column names`, `string literals`) | online | online | contradiction between the two pages |
| `status = owner qualified` | refused, "no longer supported" (21023) | | |
| `dest_table`, `destination_owner`, `pre_creation_cmd`, `schema_option`, `type`, `filter` | snapshot + reinit | reinit | `pre_creation_cmd`, `schema_option`: snapshot only |
| `creation_script`, `sync_object` | snapshot | | not documented |
| row filter (`sp_articlefilter`): add, change the clause, drop (NULL clause) | snapshot + reinit | | snapshot + reinit |
| column filter (`sp_articlecolumn`), drop or add a column, on a subscribed article | snapshot + reinit | reinit | the `sp_articlecolumn` page says only an unsubscribed article can be filtered: wrong |

Empty cells were not measured. `identity_range` and `threshold` concern updatable subscriptions and are out of scope.

On a snapshot publication the matrix differs for the commands: `ins_cmd`, `upd_cmd` and `del_cmd` need the reinit flag, and both flags with a ready snapshot (`09-snapshot-pub` `SNAP.A06` to `A09`, `SNAPI.A06` to `A09`), while the same changes on a transactional twin are online (`TWIN.A01` to `A04`). Changing `filter` to the filter procedure of another publication is not measurable: on 2022 CU27 it ends the connection with an assertion (Msg 3624, severity 20), see "Contradictions with Microsoft Learn" below.

The commands change online, but the procedure they name must exist at the subscriber: the plan cannot check that from the publisher, and must say so when it changes a command to a CALL form. A procedure name given without a schema is stored without one (`CALL [sp_MSins_dboOrders]`), unlike the generated ones (`CALL [dbo].[sp_MSins_dboOrders]`); the plan must compare commands as stored.

### Structural operations

| Operation | Effect | Source |
|---|---|---|
| Add an article, `immediate_sync = true` | `@force_invalidate_snapshot = 1` required when the snapshot is ready; existing subscriptions are subscribed to it at once by `sp_addarticle`; the snapshot is regenerated for the whole publication under every `sync_method`, only the new article is delivered | [X] lab row 9; `15-snapshot-scope` `A.imm.*`; `06-structural` `C4.imm-*` |
| Add an article, `immediate_sync = false` | no flag; each existing subscription must be extended, by name under `native`, `character` and `database snapshot`, with `@article = 'all'` under `concurrent` and `concurrent_c` (a name is refused with 14100: `15-snapshot-scope` `D.non_native_pub.extend`, `D.non_concurrent_pub.extend`, and the panel); the snapshot covers the new article alone, under every method | [L] `sp_addpublication`, `@immediate_sync` parameter; [X] lab row 10; `15-snapshot-scope` `A.non.*`; `06-structural` `C4.nonimm-*` |
| Extend a subscription explicitly on an `immediate_sync` publication | refused, with `'all'` with 14058 ("already exists"), by name with 14122 under `native` and with 14100 under `concurrent` (the campaign measured `'all'` only under `concurrent`, `15-snapshot-scope` `D.imm_concurrent.extend_rule`; the name under `concurrent`: panel, Mistral), whether or not anything is marked for reinitialization | [X] `15-snapshot-scope` `D.imm_native.*`, `D.imm_concurrent.*` |
| Extend a subscription that a change has just marked for reinitialization, without `immediate_sync` | accepted, by the rule of the row above it: by name on `native` with one article marked, `'all'` on `concurrent` or `concurrent_c` with one or every article marked; the next snapshot delivers the marked and the new articles. No row covers a `native` or `character` publication with every row marked, then a named extension | [X] `15-snapshot-scope` `D.non_native.*`, `D.non_concurrent.*`, `D.non_native_pub.*`, `D.non_concurrent_pub.*` |
| A refused `sp_add*` / `sp_change*` call | leaves its transaction open: the caller must check `@@TRANCOUNT` and roll back | [X] lab row 11; `03-add-article` `C3` |
| Row filter given only as `sp_addarticle @filter_clause` | filters the snapshot, not the changes: never generate it; always use `sp_articlefilter` | [X] lab row 12; `04-filter-clause` `F1` |
| `sp_articlecolumn` on an article with a view | rebuilds the view when the article has a subscription (status 1 or 2), not when it has none, even with the reinit flag | [X] `14-filter-view` `F6`, `F6r`, `F6s`, `F6u` |
| `sp_articlefilter` with a new clause | rewrites the filter procedure and `filter_clause`, leaves the view on the old clause | [X] `14-filter-view` `F2b`, `F2bs`, `F2bu` |
| Drop an unsubscribed article | `@force_invalidate_snapshot = 1` needed exactly when `immediate_sync_ready = 1` | [X] `06-structural` `C2.*`; `05-snapshot-flag` `S*.O2` |
| Drop a subscribed article | not directly; drop the subscription to that article first (`sp_dropsubscription @article`) | [L] *Add Articles…*, *Manually remove replication*; [X] `06-structural` `C2.*` |
| Drop an article and add it back | the next snapshot delivers that article alone; the other articles are not sent again; on `immediate_sync` the subscription is extended by `sp_addarticle` | [X] `06-structural` `C3.*` |
| Drop the subscription to one article of an `immediate_sync` publication | it cannot be added back unless the subscriptions to all articles are dropped and re-added at once | [L] `sp_dropsubscription`, Remarks |
| Drop a whole subscription | `sp_dropsubscription @article = 'all'`, no flag, nothing left | [X] `06-structural` `C1.*` |
| Drop an article or a publication | objects stay at the publisher and at the subscriber | [L] |
| Drop a publication | not possible while subscriptions remain; after them, no flag and nothing left; dropping the last publication of a database also drops its log reader agent, its job and its `MSpublisher_databases` row | [L] `sp_droppublication`; [X] `06-structural` `C5.*`; `13-transient` `T02`, `T04`, `T06`, `T08`, `T10` |
| Drop the last subscription of a shared distribution agent | the agent row and its job disappear with it, not before | [X] `07-changes` `SHR.after1`, `SHR.after2` |
| Drop a pull subscription | at the subscriber first (`sp_droppullsubscription`), then at the publisher: nothing left at any step. The other order leaves the pull agent running and failing with 21021 until the subscriber drop | [X] `08-pull` `P3.*` |
| Re-add a subscription initialized without a snapshot | "replication support only" loses the rows written in the gap, silently; the original backup or LSN replays delivered rows and fails on 14151; a fresh `COPY_ONLY` backup, or `initialize from lsn` with the subscriber's `transaction_timestamp`, delivers every gap row | [X] `10-init-modes` `I1.*.gap`, `I2.backup.gap-*`, `I3.lsn.gap-*` |
| What sets the subscription status 2 and the article's active bit | the generation of the snapshot, with the distribution agent stopped and nothing delivered | [X] `15-snapshot-scope` `E.*` |
| Change an agent account or password (`sp_changesubscription`, `sp_changelogreader_agent`…) | takes effect when the agent restarts | [L] `sp_changesubscription` |
| `sp_changesubscriber` | writes `MSsubscriber_info` and `MSsubscriber_schedule` only, no job and no agent row | [X] `07-changes` `SBR.*` |

The `immediate_sync` / `sp_dropsubscription` row is the most dangerous one for an automatic tool. A plan that removes an article and adds it back, in an `immediate_sync` publication, must be refused or turned into a full reinitialization, with a warning.

### Contradictions with Microsoft Learn

Candidates for a later correction of the documentation. Nothing has been filed with Microsoft. Each is measured on 2022 CU27.

| Learn says | Measured | Case |
|---|---|---|
| default `schema_option` of a table article is `0x30F3` (`sp_addarticle`) | `0x30073` | `01-articles` `A2`; `11-defaults` `D.sp_addarticle.table.native.@schema_option` |
| `sysschemaarticles.pre_creation_cmd` 1 = Delete, 2 = Drop | the default `drop` is stored as 1, as in `sysarticles` | `01-articles` `A8` |
| a column filter can only be changed on an unsubscribed article (`sp_articlecolumn`) | accepted on a subscribed article, with the flags of the matrix | `02-matrix` `F04` to `F06`; `14-filter-view` `F6s` |
| changing `ins_cmd`, `upd_cmd`, `del_cmd` needs a new snapshot and a reinitialization | online on a transactional publication; reinit on a snapshot publication | `02-matrix` `A06` to `A09`; `09-snapshot-pub` `TWIN.A01` to `A04`, `SNAP.A06` to `A09` |
| `pre_creation_cmd` and `schema_option` need a new snapshot only | they also need a reinitialization | `02-matrix` `A10` to `A13` |
| `sync_method` needs a new snapshot only | a change from or to `concurrent` or `concurrent_c` needs a reinitialization; between `native`, `character` and `database snapshot` it marks nothing | `02-matrix` `P21`, `P22`; `15-snapshot-scope` `C.*.sync_method`, `D.*.sync_method_probe` |
| `pre_snapshot_script` and `post_snapshot_script` need a reinitialization | the snapshot flag only, on a ready `immediate_sync` snapshot; online otherwise | `02-matrix` `P33` to `P35` |
| the two `sp_changearticle` pages disagree on `status` | `include column names` and `string literals` change online | `02-matrix` `A14` to `A16` |
| `sp_changesubscriber`: "Any distribution task for the Subscribers to this Publisher is updated" | no job, job step or agent row changes | `07-changes` `SBR.*` |
| `sp_change_subscription_properties`: a NULL `dts_package_password` leaves the password unchanged | refused with 21732 | `08-pull` `P2.dts_package_password` |
| `sp_change_subscription_properties` lists 28 properties | `distributor` and `memory_optimized` are accepted too (an omission) | `08-pull` `P2.distributor`, `P2.memory_optimized` |

One more is not a documentation error but a candidate engine bug: `sp_changearticle @property = 'filter'` with the filter procedure of another publication ends the connection with an assertion (Msg 3624, severity 20) on 2022 CU27, eight times while `09-snapshot-pub` was written (`SNAP.A22` and `SNAPI.A22` therefore measure the same value only). `CHECKDB` was clean afterwards. The planner never emits that call.

## 6. Order of operations

Proposed order for apply, inferred from the constraints above [I]:

1. drop subscriptions to removed articles;
2. drop removed articles;
3. change publication properties, in the order imposed by the `allow_anonymous` → `immediate_sync` → `independent_agent` chain and by the prerequisites of section 5 (`alt_snapshot_folder` before `compress_snapshot`…); a change of `independent_agent` is a drop and re-add of the subscriptions [X];
4. change kept articles;
5. add articles;
6. add subscriptions, or subscriptions to the new articles when `immediate_sync = false`;
7. run the snapshot if a step invalidated it, then reinitialize if a step requires it.

## 7. Outside the declarative file

- Passwords: `subscriber_password`, `publisher_password`, `MSdistpublishers.password` and `ftp_password` are encrypted. The file refers to them by name, and the tool reads them from an external source (environment variable, vault) at apply time.
- Runtime state: subscription `status`, sequence numbers, `immediate_sync_ready`, history.
- Agent Windows accounts: exported (read through `sysjobsteps` → `sysproxies` → `sys.credentials`), without their secret.

## 8. Technical choices in Go

- Driver: `github.com/microsoft/go-mssqldb`.
- Reading: direct queries on the tables of section 3, not through `sp_help*`. The `sp_help*` procedures format their output for humans and call the `sp_MSrepl_*` procedures we cannot read.
- File format: YAML, to be confirmed. `schema_option` must decode to readable option names rather than a hexadecimal number, otherwise the diff is unreadable.
- Test oracles, read-only:
  - `Export-DbaReplServerSetting` (dbatools 2.7.27, installed on this machine) calls RMO `ReplicationServer.Script()`. It is the reference for the step 2 export.
  - RMO in `SqlExecutionModes.CaptureSql` mode is the reference for the T-SQL generated by step 3.
- dbatools: checked on 2026-11-10, its replication commands are unitary (`Get-`, `Add-`, `New-`, `Remove-DbaRepl*`). No `Set-` command and no state diff.

## 9. Measurements to run on an instance

SQL Server Express can be a push subscriber, since the agent runs at the distributor, but neither a publisher nor a distributor [L] (tutorial *Prepare SQL Server for replication*). The measurements run on the lab of `lab/README.md`: one SQL Server 2022 Developer container, distributor, publisher and subscriber at once.

Method: on a publication with a valid snapshot and an active subscription, call each `sp_change*` with the four combinations of the two flags, each in a transaction rolled back (`lab/campaign/02-matrix.sql`). The campaign scripts of `lab/campaign/` extend the method to the other states and operations. The export taken before and after the script must be identical, which checks that the rollbacks leave nothing behind.

Priorities:

1. ~~the effect of `immediate_sync`, `independent_agent` and `allow_anonymous`~~ done [X];
2. ~~the snapshot generated when an article is added, depending on `immediate_sync`~~ done [X];
3. ~~article `status` and `filter`, where the two Learn pages disagree~~ done [X];
4. ~~`sp_articlecolumn` on a subscribed article~~ done [X];
5. ~~decoding of `sysschemaarticles.pre_creation_cmd`~~ done [X];
6. ~~the undocumented article properties of section 5~~ done [X], `working_directory` included (`07-changes`);
7. ~~whether a filter clause stored by `sp_addarticle` without a filter procedure filters anything~~ done [X]: the snapshot only.

## 10. Next step

Steps 1 and 2 are done, and the measurements of section 9 that gate step 3 are made, together with the campaign of the plan/apply design (`lab/README.md`, "The campaign"). Step 3, the plan, takes its rules from section 5 and from the design, which cites the campaign rows.
