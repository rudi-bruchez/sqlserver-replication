# Step 1 — Analysis: state to read, impact matrix, technical choices

Todoist task: "Declarative configuration layer for SQL Server transactional replication: analysis then implementation". Language chosen on 2026-11-10: Go.

Source legend:

- **[L]** Microsoft Learn, read on 2026-11-10;
- **[R]** SQL Server 2019 system procedure source in this repository (`stored-procedures/`);
- **[I]** inference, to be checked;
- **[M]** to be measured on an instance.

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
| `syssubscriptions` | one row **per article and per subscriber** | filter `srvid >= 0`: -1 and -2 are virtual subscribers [R] `sp_MSadd_subscription.sql:142-143` |

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

**`syspublications`**

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

**`sysarticles`**

| Column | Values |
|---|---|
| `type` | 1 = logbased; 3 = + manual filter; 5 = + manual view; 7 = both; 8 = proc exec; 24 = serializable proc exec; 32, 64, 128 = schema-only procedure, view, function |
| `status` (bitmask) | 1 = active; 8 = column names in INSERT; 16 = parameterized commands |
| `pre_creation_cmd` | 0 = none, 1 = DROP, 2 = DELETE, 3 = TRUNCATE |
| `schema_option` | `binary(8)`, read as a big-endian `uint64` [I]; 44 bits documented on the `sp_changearticle` page; default `0x30F3` for a table article |
| `ins_cmd`, `del_cmd` | `CALL`, `XCALL` (del), `SQL`, `NONE` |
| `upd_cmd` | `CALL`, `MCALL`, `SCALL`, `XCALL`, `SQL`, `NONE` |

`ins_cmd`, `upd_cmd` and `del_cmd` are stored as text, together with the procedure name (`CALL [sp_MSins_dboT]`). The declarative file should split the mode (`CALL`) from the procedure name, and carry the name only when it differs from the generated one [I].

For `sysschemaarticles.pre_creation_cmd`, Learn gives 1 = Delete and 2 = Drop, the reverse of `sysarticles`. **[M]**

**`syssubscriptions`**

| Column | Values |
|---|---|
| `subscription_type` | 0 = push, 1 = pull |
| `sync_type` | 1 = automatic, 2 = none |
| `nosync_type` | 0 = snapshot, 1 = replication support only, 2 = backup, 3 = LSN |
| `status` | 0 = inactive, 1 = subscribed, 2 = active; runtime state, not configuration |

## 5. Impact matrix

This matrix matters because of how the procedures behave. A `sp_change*` call with `@force_invalidate_snapshot = 0` and `@force_reinit_subscription = 0` fails without changing anything when the change requires either flag [L]. The plan must know in advance which flags to pass, and say so.

### Publication properties (`sp_changepublication`)

| Property | New snapshot | Reinitialization | Source |
|---|---|---|---|
| `sync_method` | yes | — | [L] *Change Publication and Article Properties*; the `sp_changepublication` page says `sync_mode`, which is the merge property name |
| `alt_snapshot_folder`, `snapshot_in_defaultfolder`, `compress_snapshot` | yes | — | [L] both pages |
| `enabled_for_internet`, `ftp_*` | yes | — | [L]; `enabled_for_internet` only appears on the *Change…* page |
| `pre_snapshot_script`, `post_snapshot_script` | yes | needed to apply the script at the subscriber | [L] *Change…* |
| `enabled_for_het_sub` | yes | — | [L]; not possible while subscriptions exist |
| `working_directory` (`sp_changedistpublisher`) | yes | — | [L] *Change…* |
| `description`, `retention`, `replicate_ddl`, `allow_push`, `allow_pull`, `allow_initialize_from_backup`, `allow_subscription_copy`, `allow_partition_switch`, `replicate_partition_switch`, `allow_drop`, `status` | not documented | not documented | presumed online **[M]** |
| `immediate_sync`, `independent_agent`, `allow_anonymous` | not documented | not documented | **[M]**, first priority: these three change how an added article is initialized |

Dependencies between properties [L]: `allow_anonymous = true` requires `immediate_sync = true`, which in turn requires `independent_agent = true`. The plan must order changes accordingly: enable from the bottom of the chain up, disable from the top down [I].

### Article properties (`sp_changearticle` and related procedures)

| Property | Snapshot | Reinit. | Source |
|---|---|---|---|
| `description` | — | — | [L] the only property changeable in P2P along with the commands, so presumed online |
| `schema_option` | yes | — | [L] both pages; writing replaces the whole mask instead of applying it bitwise, so the plan must send the complete value |
| `pre_creation_cmd` | yes | — | [L] both pages |
| `ins_cmd`, `upd_cmd`, `del_cmd` | yes | yes | [L] both pages |
| `dest_table`, `destination_owner` | yes | yes | [L] both pages |
| `status` | *Change…*: yes | `sp_changearticle`: yes | **contradiction [M]** |
| `filter` | *Change…*: yes | yes | `sp_changearticle` only asks for reinitialization **[M]** |
| row filter (`sp_articlefilter`, add, change, drop) | yes | yes | [L] *Change…* |
| column filter (`sp_articlecolumn`) | yes | yes | [L] *Change…*; the `sp_articlecolumn` page adds that only an unsubscribed article can be filtered **[M]** |
| `creation_script`, `fire_triggers_on_snapshot`, `sync_object`, `type`, `identity_range`, `threshold` | not documented | not documented | **[M]** |

### Structural operations

| Operation | Effect | Source |
|---|---|---|
| Add an article | new snapshot; `@force_invalidate_snapshot = 1` if a snapshot exists; only the new article is sent, the publication is not reinitialized | [L] *Add Articles to and Drop Articles from Existing Publications* |
| Add an article, `immediate_sync = false` | `sp_addsubscription` must be called for each existing subscription | [L] `sp_addpublication`, `@immediate_sync` parameter |
| Add an article, `immediate_sync = true` | snapshot of the article alone or of the whole publication | **[M]** |
| Drop an unsubscribed article | free; invalidates the snapshot | [L] |
| Drop a subscribed article | not directly; drop the subscription to that article first (`sp_dropsubscription @article`) | [L] *Add Articles…*, *Manually remove replication* |
| Drop the subscription to one article of an `immediate_sync` publication | it cannot be added back unless the subscriptions to **all** articles are dropped and re-added at once | [L] `sp_dropsubscription`, Remarks |
| Drop an article or a publication | objects stay at the publisher and at the subscriber | [L] |
| Drop a publication | not possible while subscriptions remain | [L] `sp_droppublication` |
| Change an agent account or password (`sp_changesubscription`, `sp_changelogreader_agent`…) | takes effect when the agent restarts | [L] `sp_changesubscription` |

The `immediate_sync` / `sp_dropsubscription` row is the most dangerous one for an automatic tool. A plan that removes an article and adds it back, in an `immediate_sync` publication, must be refused or turned into a full reinitialization, with a warning.

## 6. Order of operations

Proposed order for apply, inferred from the constraints above [I]:

1. drop subscriptions to removed articles;
2. drop removed articles;
3. change publication properties, in the order imposed by the `allow_anonymous` → `immediate_sync` → `independent_agent` chain;
4. change kept articles;
5. add articles;
6. add subscriptions, or subscriptions to the new articles when `immediate_sync = false`;
7. run the snapshot if a step invalidated it, then reinitialize if a step requires it.

## 7. Outside the declarative file

- **Passwords**: `subscriber_password`, `publisher_password`, `MSdistpublishers.password` and `ftp_password` are encrypted. The file refers to them by name, and the tool reads them from an external source (environment variable, vault) at apply time.
- **Runtime state**: subscription `status`, sequence numbers, `immediate_sync_ready`, history.
- **Agent Windows accounts**: exported (read through `sysjobsteps` → `sysproxies` → `sys.credentials`), without their secret.

## 8. Technical choices in Go

- **Driver**: `github.com/microsoft/go-mssqldb`.
- **Reading**: direct queries on the tables of section 3, not through `sp_help*`. The `sp_help*` procedures format their output for humans and call the `sp_MSrepl_*` procedures we cannot read.
- **File format**: YAML, to be confirmed. `schema_option` must decode to readable option names rather than a hexadecimal number, otherwise the diff is unreadable.
- **Test oracles**, read-only:
  - `Export-DbaReplServerSetting` (dbatools 2.7.27, installed on this machine) calls RMO `ReplicationServer.Script()`. It is the reference for the step 2 export.
  - RMO in `SqlExecutionModes.CaptureSql` mode is the reference for the T-SQL generated by step 3.
- **dbatools**: checked on 2026-11-10, its replication commands are unitary (`Get-`, `Add-`, `New-`, `Remove-DbaRepl*`). No `Set-` command and no state diff.

## 9. Measurements to run on an instance

The local instance is SQL Server Express. It can be a push subscriber, since the agent runs at the distributor, but neither a publisher nor a distributor [L] (tutorial *Prepare SQL Server for replication*). A Developer edition is needed as publisher and local distributor, with the Express instance as subscriber.

Method: on a publication with a valid snapshot and an active subscription, call each `sp_change*` with both flags at 0. If the call fails, record the message; if it succeeds, the property changes online. Then replay with `@force_invalidate_snapshot = 1` alone. This yields the real matrix, property by property, in a few dozen scripted calls.

Priorities:

1. the effect of `immediate_sync`, `independent_agent` and `allow_anonymous`;
2. the snapshot generated when an article is added, depending on `immediate_sync`: article alone or whole publication;
3. article `status` and `filter`, where the two Learn pages disagree;
4. `sp_articlecolumn` on a subscribed article;
5. decoding of `sysschemaarticles.pre_creation_cmd`;
6. the undocumented article properties of section 5.

## 10. Next step

Step 2, the export, can start without these measurements: it only reads the tables of section 3. The measurements of section 9 gate step 3, the plan.
