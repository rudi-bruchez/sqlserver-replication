# sqlrepl plan 2: model and export extension Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the YAML model and the read-only export so that they hold every parameter of the in-scope procedures, tell an omitted property from a zero one, and give plan 3 the current configuration, its findings and the observed runtime facts it needs.

**Architecture:** `internal/model` keeps the file format: scalar properties become pointers so that a loaded file tells "omitted" from "zero", and the package gains `Load`, element paths, a completeness walker (`NilProperties`) and the table that maps every procedure parameter to a field or an exclusion. `internal/reader` returns a `Result` holding a `model.Config` and a `state.Facts`, the second being the runtime facts, kept out of the file. The export stays read-only (`SELECT` only), reads pull subscriptions through an optional subscriber connection, and writes the facts as JSON through a separate flag.

**Tech Stack:** Go 1.26.5 (existing module, no new dependency: `gopkg.in/yaml.v3`, `github.com/microsoft/go-mssqldb`, the standard library), T-SQL, the lab container `repllab` (SQL Server 2022 CU27 Developer), bash for the lab scripts.

**Spec:** `docs/superpowers/specs/2026-11-10-sqlrepl-plan-apply-design.md`, section "Extending the model and the export" and every place that assigns work to plan 2 or to the reader: "Inputs" (the facts, the split of `warnings`, the empty configuration, errors never read as absence), "Shared distributor objects" (every profile), "Filters and views" (the reader's warnings), "Blocking" (`sync_method` 5 and 6), "apply" step 3 (the snapshot job's own enabled state), "Secrets". Background: `CLAUDE.md` (traps already paid for), `lab/README.md`, `lab/results/2022/11-defaults.txt`, `lab/results/2022/distributor-defaults.txt`, `lab/results/2022/08-pull.txt`. House style: `docs/superpowers/plans/2026-11-10-sqlrepl-1-rename-and-campaign.md`.

This is the second of four plans. Plan 3 (normalization, defaults table, cost table, comparison, `plan`) consumes what this plan produces; its inputs are listed at the end, under "What plan 3 receives".

## Scope rulings of the controller

Recorded as given by the controller of this plan, not decided here:

- In plan 2: the model (YAML format), the reader and the export, and the decode tables they need. The export stays read-only.
- Not in plan 2: normalization, the defaults table, the cost table, the comparison and `plan` (plan 3); `apply`, `snapshot`, the report, secrets loading and `internal/dotenv` (plan 3 or 4, whichever needs them first).
- Subscriber connections: plan 2 reads at a subscriber only what the export needs for pull subscriptions, through an optional connection flag (decided below: `-server`).
- The observed runtime facts are not part of `model.Config`. They are a separate Go type returned by the reader and exported by a separate flag, so that plan 3's planner takes (desired `Config`, current `Config`, `Facts`).
- How the model marks omitted properties is decided in this plan, with its reason; the export keeps writing every property.
- `sys.all_parameters`: a task lists the parameters of each in-scope procedure on the lab and commits the list; a Go table maps each one to a field or to a documented exclusion, with a test that fails when a listed parameter has neither. `lab/start.sh` accepts `2019`, `2022` and `2025` (read on 2026-11-11), so a task replays the listing on 2019 and 2025.

## Rulings made in this plan

Each is a decision the spec leaves to the builder or a place where the code or a measurement disagrees with the spec. The reason is given once, here.

- Omitted properties are nil pointers. Every scalar property of the model becomes `*T`, every list whose empty value means something becomes `*[]T`; identity fields (names, server, database) stay plain. Reason: the distinction then travels with the value through loading, normalization (plan 3) and JSON for the GUI, with no side structure keyed by path, and `yaml.v3` keeps it both ways: a nil pointer with `omitempty` is not written, `false`, `0`, `""` and `[]` are (checked on 2026-11-11 with yaml.v3 v3.0.1: `*[]string` keeps `[]` through a round trip, `[]string` with `omitempty` loses it).
- For a string property, `""` in the file is the SQL `NULL` of the stored column (the export writes `""` for `NULL`). No in-scope string column distinguishes `NULL` from the empty string in its meaning.
- Findings replace `warnings`, with four kinds: `out_of_scope` (plan 3 refuses the database), `incomplete` (an in-scope object in a state plan 3 repairs), `unreadable` (a value the reader could not see; the property is nil and plan 3 must not read it as a change), `note` (informational: undecoded bits that round-trip, secret name clashes). Each finding has a path in the model's path syntax. They stay in the file under `findings:`, as `warnings:` did, because an exported file must show them; `Load` accepts them and plan 3 ignores them in a desired file.
- `FormatVersion` becomes 2: keys change (`warnings`, `active`, secret names) and `Load` refuses any other version.
- Secret names become environment variable names. The spec reads a secret from "the environment variable of that name" (spec line 329); today's names (`publisher/REPLLAB`, `subscriber/S/db`, `ftp/<publication>`) contain `/` and cannot be exported from a shell. A secret is now the password of one login on one server, named `SQLREPL_<KIND>_<PART>_<PART>…`, upper case, every character outside `A-Z0-9` replaced by `_`. Kinds: `SQL` (server, login), `WIN` (job account), `FTP` (address, login), `STORAGE` (publisher). Two agents that use the same login on the same server share one secret, which is what the password is. A clash between two different sources after sanitizing gets a suffix `_2`, `_3` in reading order and a `note` finding.
- The `active` bit of a table article leaves the model for the facts: the spec calls it runtime state (spec line 104), and the model has carried it since step 2 (`internal/model/model.go:171`).
- The job account compared by plan 3 is `job_login`, read from `MSlogreader_agents`, `MSsnapshot_agents`, `MSdistribution_agents` and, for a pull agent, the subscriber's `MSsubscription_properties`, where the procedures store `@job_login` (`11-defaults` rows `D.sp_add*_agent.*.@job_login`). `run_as`, the proxy credential of the job step, stays in the export as derived information, never compared, and is the property the spec's visibility rule applies to (spec line 366): a proxy whose credential the login cannot see is nil with an `unreadable` finding, never `""`.
- The empty configuration means "no publication". When the publisher has a distributor, the distributor section is still read, because plan 3 must not create a distributor that exists; when this publisher is not registered there and the database is not published, the section holds only `server`, with a `note` finding. A database published for merge only also has `is_published = 0` (spec line 140): it gets the empty configuration plus an `out_of_scope` finding, so that plan 3 refuses it.
- `enabled_for_het_sub` is a field (spec line 215 plans its change) and, when true, also an `out_of_scope` finding (non-SQL Server subscribers, spec line 51).
- The procedures mapped are the 18 that create configuration: `sp_adddistributor`, `sp_adddistributiondb`, `sp_adddistpublisher`, `sp_replicationdboption`, `sp_addlogreader_agent`, `sp_addpublication`, `sp_addpublication_snapshot`, `sp_addarticle`, `sp_articlefilter`, `sp_articleview`, `sp_articlecolumn`, `sp_addsubscription`, `sp_addpushsubscription_agent`, `sp_addpullsubscription`, `sp_addpullsubscription_agent`, `sp_add_agent_profile`, `sp_add_agent_parameter`, `sp_update_agent_profile` (316 parameters on 2022 CU27, counted on the lab on 2026-11-11). The `sp_change*` procedures change the same properties through `@property` and `@value`: their property vocabulary is the cost table's (plan 3). `sp_addsubscriber` is left out: it is deprecated and `sp_addsubscription` registers the subscriber.
- Parameters that the server does not store (the backup and LSN parameters of `sp_addsubscription`, the file sizes and the login of `sp_adddistributiondb`, `11-defaults` and `distributor-defaults` rows `no-column`) are `creation_only` fields: they exist in the model so that plan 3 can pass them, the export never writes them, and plan 3 never compares them. The spec asks the export to write every property (spec line 98) and the model to hold these (spec line 356); both cannot hold for them.
- `sp_replicationdboption @optname = 'sync with backup'` is configuration of the publication database and becomes `publisher.sync_with_backup`, read with `DATABASEPROPERTYEX(<db>, 'IsSyncWithBackup')`.
- Two bits of `syspublications.options` were measured while writing this plan, in a transaction rolled back on the lab: `allow_partition_switch` alone stores `0x20`, with `replicate_partition_switch` `0x60`. `sync_method = 'database snapshot'` stores 5 and `'database snapshot character'` 6 (spec line 294 says so; measured again).
- The subscriber connection flag is `-server NAME=ADDRESS`, repeatable, the form the spec gives as an example (spec line 339). `NAME` is a server name as replication stores it, matched without regard to case; `ADDRESS` is what `-publisher` accepts. It also resolves the distributor name when `-distributor` is not given. The export opens every subscriber named by `-server` with the same credentials as the publisher; a pull subscription whose subscriber has no `-server` entry is exported from the publisher side only, its subscriber side nil with an `unreadable` finding. A mapped subscriber that cannot be reached is an error.
- The facts are a package of their own, `internal/state`, written as JSON by `sqlrepl export -facts <path>`. JSON because the plan's `-json` and the GUI use JSON; a flag of the export rather than a subcommand because they are read in the same pass and the same connections, and kept out of the YAML because they change at every run (the campaign's `export` guard compares two exports of `Sales`). Times are the distributor's clock, written `2006-01-02 15:04:05.000` without a zone, since the `datetime` columns carry none.
- Every profile of the distributor goes in the file (`agent_profiles`, the user-defined ones of the in-scope agent types), since the file may create and change them; which agents use them, for every database at the distributor, is a fact (`ProfileUses`), since it describes databases the file does not.
- The synchronization view definition is not exported; the reader checks it against the article's clause and published columns and reports a mismatch as `incomplete`. The format checked is the one `sp_articleview` writes, read on the lab on 2026-11-11 (Task 8). The spec says both that the export reads the definition "enough to check it" (spec line 365) and that the export "cannot see a synchronization view out of step with its filter" (spec line 404): the first holds for the text of the view, the second for its effect on the data, which only the data checks of plan 3's tests see.
- Lab integration tests need `SQLREPL_TEST_DSN` (as `TestQueriesParse`) and `SQLREPL_TEST_LAB=1`. With both set, a missing lab object fails the test; with `SQLREPL_TEST_LAB` unset they skip. Reason: a test that skipped when `Sales` was missing would turn a broken lab into a green run.

## Global Constraints

- Everything written in the repository (code, comments, docs, commit messages, results) is in English.
- Documents: no bold in paragraphs, no em dash or en dash, titles that announce their subject without a conclusion or a count.
- Commit messages: a prose body that says why; no `Co-Authored-By`, `Claude-Session`, `Generated with` or any other attribution trailer. Stage explicit paths, never `git add -A` or `.`.
- No new Go dependency. `go build ./cmd/sqlrepl`, `go vet ./...` and `test -z "$(gofmt -l .)"` pass at the end of every task, and so does `go test ./...` without a DSN.
- The Go module path stays `github.com/rudi-bruchez/sqlserver-replication`.
- The model holds configuration only: no runtime state, no secret; a password appears as a secret name (spec "Secrets", `CLAUDE.md`).
- Unknown values are never dropped: they render as `unknown(n)` or a hex bit, and every `*Code` / `Encode*` inverse accepts them (`CLAUDE.md`, `internal/decode`). Every new code table keeps that invariant.
- Server names are compared without regard to case (spec "Names", `CLAUDE.md`).
- The export runs `SELECT` statements only. A read that fails is an error, never an absence (spec "Inputs"). Every new query is added to the map of `TestQueriesParse`.
- Unit tests need no server. Lab tests are gated as described in "Rulings" and run through `lab/gotest.sh` (Task 4) in one shell invocation that loads the password:

  ```
  set -a; . ~/Sources/Repos/atelier/livres-informatiques/optimiser-sql-server/edition-2026/harnais/.env; set +a
  lab/gotest.sh '<anchored filter>' ./internal/reader
  ```

  The password is only loaded that way and passed by variable name (`SQLCMDPASSWORD`, `MSSQL_SA_PASSWORD`); never printed, never on a command line, never `-P`, never `bash -x`. A DSN is built and URL-encoded inside the same invocation (`lab/gotest.sh` does it). Tests never print a DSN.
- Every test step names its `-run` filter, anchored, and the exact number of `--- PASS` lines expected, with no `--- SKIP` and no `--- FAIL`. Any other number, larger included, means the filter or the work is wrong.
- Every task has a break step: break the code as it says, run the named test, see it fail, restore. A report of "one failed, the others passed" is the success of that step.
- Lab: container `repllab` on `127.0.0.1:11980`, started by `lab/start.sh 2022` (it recreates the container). Check `podman ps` before a lab step and start it if it is not running. Tests create only objects named `m_` (tables, publications, databases), remove them in `t.Cleanup` even when the test fails, and touch the lab's own objects (`Sales`, `SalesSub`, `SalesPub`, `SalesRef`) only by reading. SQL Server is stopped with `SHUTDOWN WITH NOWAIT`, never `podman stop`. No other container is touched (`rpllab1` to `rpllab3`, `sql2022`, `sql2025` and the rest).
- If a measurement or a test contradicts this plan or the spec, stop and report what was measured. Do not change the code until it agrees with the document.

## Review Focus

1. Server names that differ in case between the flag, the publisher and the subscriber (`syssubscriptions.srvname` is `REPLLAB`, `@@SERVERNAME` is `repllab`, the user types either): a `-server repllab=...` entry must serve a subscription stored as `REPLLAB`. Pinned by `TestServerFlags` (Task 10) and by the lowercase key of `TestReadLabPullSubscription` (Task 10).
2. A hand-written file with explicit zero values (`false`, `0`, `""`, `[]`) beside omitted ones: each must load as what it says, the zero values non-nil, the omitted ones nil. Pinned by `TestLoadOmittedVsZero` (Task 3).
3. Names that must be quoted where the reader splices them into SQL (a subscription database `m sub]1`, a distribution database with `]`): the spliced text is `QUOTENAME`'s. Pinned by `TestSubscriberQueryQuotesDatabase` (Task 10).
4. A publication database that is offline, restoring, in standby or merge-published only, against one that is simply not published: errors for the first three, the empty configuration for the last two, with an `out_of_scope` finding for merge. Pinned by `TestStartDecision` (Task 5).
5. A login that cannot see a job's proxy or its credential: the run-as account must be nil with an `unreadable` finding, never `""`, which plan 3 would read as "runs as the Agent service account". Pinned by `TestRunAs` (Task 7).

---

### Task 1: Parameter listing on 2022

Files:
- Create: `lab/campaign/17-parameters.sql`, `lab/results/2022/17-parameters.txt`
- Modify: `lab/README.md` (a section "Procedure parameters", and the row `17` in "Planned and measured totals")

Interfaces:
- Produces: `lab/results/<version>/17-parameters.txt`, lines `R|<procedure>.<parameter>|<type>(<max_length>)|output=<0|1> id=<parameter_id>`, then `R|TOTAL|<n>`, read by `TestParametersCovered` (Task 12). `<procedure>` has no schema (`sp_addarticle`), `<parameter>` keeps its `@`.

- [ ] Step 1: Write `lab/campaign/17-parameters.sql`. It is read-only and creates nothing. It selects from `sys.all_objects` joined to `sys.all_parameters`, `schema_id = SCHEMA_ID(N'sys')`, `name IN` the 18 procedures of "Rulings", ordered by procedure name then `parameter_id`, one `R|` row each, `TYPE_NAME(user_type_id)` for the type, then the `TOTAL` row, in the format of `01-articles.sql` (rows in a table variable, one final `SELECT`, every column cast to `nvarchar(4000)`).
- [ ] Step 2: Run it, in one shell: load the password, `lab/campaign.sh 2022 lab/campaign/17-parameters.sql`. Expected: exit 0, `R|TOTAL|316` in `lab/results/2022/17-parameters.txt`, and 18 distinct procedure names in it (`grep '^R|sp_' lab/results/2022/17-parameters.txt | cut -d'|' -f2 | cut -d. -f1 | sort -u | wc -l` prints 18). Per procedure, the counts measured on 2026-11-11: `sp_add_agent_parameter` 3, `sp_add_agent_profile` 6, `sp_addarticle` 32, `sp_adddistpublisher` 11, `sp_adddistributiondb` 17, `sp_adddistributor` 6, `sp_addlogreader_agent` 8, `sp_addpublication` 49, `sp_addpublication_snapshot` 22, `sp_addpullsubscription` 8, `sp_addpullsubscription_agent` 45, `sp_addpushsubscription_agent` 31, `sp_addsubscription` 42, `sp_articlecolumn` 11, `sp_articlefilter` 7, `sp_articleview` 10, `sp_replicationdboption` 5, `sp_update_agent_profile` 3. Another count is reported, not reconciled.
- [ ] Step 3: Break step. Remove the `UNION ALL SELECT 'R|TOTAL|'…` part, rerun. Expected: `GUARD total failed`. Restore, rerun, `R|TOTAL|316` again.
- [ ] Step 4: Add the `lab/README.md` section (what the script lists, that it is read-only, the 2022 count) and the row `17-parameters` (planned 316, measured 316) to "Planned and measured totals". Commit the script, the results and the README.

### Task 2: Decode tables for the new codes

Files:
- Modify: `internal/decode/decode.go`, `internal/decode/decode_test.go`

Interfaces:
- Produces, all in `internal/decode`:
  - `syncMethods` gains `5: "database_snapshot"`, `6: "database_snapshot_character"`.
  - `PubOptionAllowPartitionSwitch = 0x20`, `PubOptionReplicatePartitionSwitch = 0x40`, both in `pubOptionKnown`.
  - `PublicationTypeCode(name string) (int, error)`, `FreqTypeCode`, `FreqSubdayTypeCode`, `AgentTypeCode` (inverses of the existing decoders).
  - `SecurityMode` becomes a `codeTable` (`0: "sql"`, `1: "windows"`) with `SecurityModeCode`.
  - `SubscriptionType(code int) string` / `SubscriptionTypeCode` over `syssubscriptions.subscription_type` and `MSreplication_subscriptions.subscription_type`: `0: "push"`, `1: "pull"`, `2: "anonymous"` (`11-defaults` `D.sp_addpullsubscription.pull.@subscription_type`).
  - `SubscriberType(code int) string` / `SubscriberTypeCode` over `MSsubscriber_info.type`: `0: "sql_server"`, `1: "odbc"`, `3: "oledb"` (Learn, `sp_addsubscription @subscriber_type`).
  - `InitializationCode(name string) (syncType, nosyncType int, err error)`, the inverse of `Initialization`, accepting its `unknown(sync_type=n,nosync_type=m)` form.

- [ ] Step 1: Write the tests. `TestSyncMethodCodes`: `SyncMethod(5) == "database_snapshot"`, `SyncMethod(6) == "database_snapshot_character"`, `SyncMethodCode` of both gives 5 and 6, `SyncMethod(2)` stays `"unknown(2)"`. Extend `TestCodeTablesRoundTrip` to loop over every `codeTable` of the package (`articleTypes`, `preCreationCmds`, `syncMethods`, `replFreqs`, `publicationStatuses`, `freqTypes`, `freqSubdayTypes`, `agentTypes`, `securityModes`, `subscriptionTypes`, `subscriberTypes`) through its exported pair, plus `unknown(97)` through each. `TestInitializationCode`: every value `Initialization` returns for `{1,0} {2,0} {2,1} {2,2} {2,3} {9,9}` goes back to its pair. `TestPublicationOptionBits`: `PublicationOptionUnknownBits(0x20|0x40) == 0` and `PublicationOptionUnknownBits(0x200) == 0x200`.
- [ ] Step 2: Run `go test -count=1 -v -run '^(TestSyncMethodCodes|TestCodeTablesRoundTrip|TestInitializationCode|TestPublicationOptionBits)$' ./internal/decode`. Expected: compile failure (undefined names).
- [ ] Step 3: Implement the interfaces above. Comment the two option bits and codes 5 and 6 with their source (measured on the lab on 2026-11-11, rolled-back `sp_addpublication`).
- [ ] Step 4: Run the Step 2 command. Expected: 4 `--- PASS`. Then `go test ./...`: all pass (12 tests in `internal/decode`).
- [ ] Step 5: Break step. Map 6 to `"database_snapshot"` as well. Expected: `TestSyncMethodCodes` and `TestCodeTablesRoundTrip` fail (two names for one inverse). Restore.
- [ ] Step 6: Commit.

### Task 3: Model with omitted properties

Files:
- Modify: `internal/model/model.go`
- Create: `internal/model/load.go`, `internal/model/path.go`, `internal/model/model_test.go`
- Modify: `internal/reader/reader.go`, `internal/reader/publisher.go`, `internal/reader/agents.go`, `cmd/sqlrepl/main.go` (mechanical: pointers, no change of what is read)

Interfaces:
- Produces, in `internal/model`:
  - `const FormatVersion = 2`.
  - `func Ptr[T any](v T) *T`.
  - `func Load(r io.Reader) (*Config, error)`: `yaml.v3` decoder with `KnownFields(true)`; refuses a document whose `version` is not `FormatVersion` with `"format version %d, this sqlrepl reads %d"`.
  - `func Marshal(c *Config) ([]byte, error)`: `yaml.Marshal`, used by the CLI.
  - `Key() string` on `Publication`, `Article`, `Schedule` (the name), `Subscription` and `SharedDistributionAgent` (`<subscriber>/<database>`), `AgentProfile` (`<agent_type>/<name>`).
  - Paths: YAML keys joined by `.`, a list element written `[<Key()>]` with `]` doubled inside the key, for example `publications[SalesPub].subscriptions[REPLLAB/SalesSub].distribution_agent.run_as`. `func Pattern(path string) string` replaces each bracketed key by `*`.
  - `type Step struct { Key string; Value any }` and the interface `omissible { OmittedOK(key string, parents []Step) bool }`, `parents` running from the root to the struct's own parent.
  - `func NilProperties(c *Config) []string`: the paths of every nil pointer field (a `*T`, `*[]T`, pointer to struct) reachable from `c`, walked by YAML tag (inline structs flattened into their parent), except fields whose struct says `OmittedOK`; `Findings` is not walked; sorted.
- Types (YAML keys in parentheses where they differ from the field name in snake case). Every field listed here as `*` is new or changed; identity fields stay plain `string`:
  - `Config`: `Distributor *Distributor` (`omitempty`); `Findings []Finding` (`findings,omitempty`, type defined here, kinds filled in Task 4: `Finding{Kind, Path, Message string}`).
  - `Publisher`: `LogReaderAgent *Agent` unchanged.
  - `Distributor`: retention fields `*int`; `WorkingDirectory *string`; `PublisherConnection *Connection`; `Trusted *bool`.
  - `Connection`: `Security`, `Login`, `PasswordSecret` all `*string`.
  - `Agent`: `JobName *string`, `Profile *string`, `RunAs *string`, `Connection *Connection`, `Schedules *[]Schedule` (`schedules,omitempty`), `Command *string`. `Schedule` keeps plain fields: a declared schedule is compared in full (spec "What is not compared").
  - `Publication`: `Description`, `Type`, `Status`, `SyncMethod *string`; `RetentionHours *int`; every bool `*bool`; `Snapshot *Snapshot`.
  - `Snapshot`: `InDefaultFolder`, `Compress *bool`; `AltFolder`, `PreScript`, `PostScript *string`; `FTP *FTP`. `FTP`: every field a pointer.
  - `Article`: `Type`, `Description`, `PreCreationCmd`, `CreationScript *string`; `Destination Destination` with `Destination{Schema *string; Name *string}` (schema `""` is a `NULL` `dest_owner`, the `character` case of the spec's defaults table); `SchemaOptions *[]string` (`schema_options,omitempty`: `[]` is "no option", omitted is the default); `InsertColumnNames`, `Parameterized`, `FireTriggersOnSnapshot *bool`; `Commands *Commands` with `Insert`, `Update`, `Delete *Command`; `Columns []string` stays a plain list (`omitempty`): omitted and empty both mean every column, which is the default and what the export writes for an unfiltered article. The field `Active` is removed (see "Rulings").
  - `Subscription`: `Initialization *string`, `LoopbackDetection *bool`; `Articles []string` stays plain (`omitempty`, nil means every article, as today).
  - `DistributionAgent`: `SubscriptionStreams *int`, `MemoryOptimized *bool`.
  - `AgentProfile`: `Description *string`, `Default *bool`.
- `OmittedOK` conditions in this task (later tasks add theirs to the same methods):

| Type | Key | Nil allowed when |
|---|---|---|
| `Connection` | `login`, `password_secret` | `security` is not `sql` |
| `Snapshot` | `ftp` | the publication is not enabled for internet (today: always, the field is set only when enabled; Task 6 makes it `enabled_for_internet` false) |
| `Article` | `insert_column_names`, `parameterized`, `commands`, `fire_triggers_on_snapshot` | `type` is `proc_schema_only`, `view_schema_only`, `aggregate_schema_only` or `func_schema_only` |
| `Article` | `filter`, `sync_object` | always (nil is "none", the default) |
| `Command` | `procedure` | `mode` is not `CALL`, `SCALL`, `MCALL` or `XCALL` |
| `Subscription` | `distribution_agent` | the enclosing publication (the nearest `*Publication` in `parents`) has `independent_agent` false |
| `Publisher` | `log_reader_agent` | the root `*Config` (first of `parents`) has no publication |

- [ ] Step 1: Write `internal/model/model_test.go`:

```go
func TestLoadOmittedVsZero(t *testing.T) {
	in := `version: 2
publisher: {server: S, database: D}
publications:
  - name: P
    immediate_sync: false
    retention_hours: 0
    description: ""
    articles:
      - name: A
        schema_options: []
      - name: B
`
	c, err := Load(strings.NewReader(in))
	// err == nil
	p := c.Publications[0]
	// p.ImmediateSync != nil && !*p.ImmediateSync
	// p.AllowPull == nil
	// p.RetentionHours != nil && *p.RetentionHours == 0
	// p.Description != nil && *p.Description == ""
	// p.Status == nil
	// p.Articles[0].SchemaOptions != nil && len(*p.Articles[0].SchemaOptions) == 0
	// p.Articles[1].SchemaOptions == nil
}
```

  `TestLoadRejectsUnknownField`: a document with `publications: [{name: P, imediate_sync: true}]` fails and the error names `imediate_sync`. `TestLoadRejectsOtherVersion`: `version: 1` fails with the message above. `TestMarshalLoadRoundTrip`: a `Config` built in Go with every pointer of one publication, one table article, one schema article, one push subscription and its agent set (zero values included) marshals and loads back `reflect.DeepEqual`. `TestNilProperties`: on a `Config` with one publication whose `Status` is nil, one schema-only article with nil `commands` and one `windows` connection with nil `password_secret`, the result is exactly `["publications[P].status"]`. `TestPathEscapesKeys`: the path of an article named `a]b` in publication `P` is `publications[P].articles[a]]b]`, and `Pattern` of it is `publications[*].articles[*]`.
- [ ] Step 2: Run `go test -count=1 -v -run '^(TestLoadOmittedVsZero|TestLoadRejectsUnknownField|TestLoadRejectsOtherVersion|TestMarshalLoadRoundTrip|TestNilProperties|TestPathEscapesKeys)$' ./internal/model`. Expected: compile failure.
- [ ] Step 3: Implement the model changes, then adapt the reader and the CLI to the pointers with `model.Ptr`, reading exactly what they read today, minus `Active`. The CLI writes with `model.Marshal`. `NilProperties` uses `reflect`; the walk is the only algorithm here: for each struct, each exported field with a YAML tag (`-` skipped, `,inline` flattened), a nil pointer is reported unless `OmittedOK`; a non-nil pointer, a struct, a slice of structs (element path from `Key()`) and a pointer to a slice of structs are descended into with the step appended to `parents`. A field reached through an inline struct is judged by the outermost struct that holds it (`PullAgent` answers for the fields of its inline `DistributionAgent` and `Agent`, delegating to their conditions).
- [ ] Step 4: Run the Step 2 command. Expected: 6 `--- PASS`. Then `go build ./cmd/sqlrepl && go vet ./... && test -z "$(gofmt -l .)" && go test ./...`: all pass.
- [ ] Step 5: Break step. Give `Publication.ImmediateSync` the type `bool` again. Expected: `TestLoadOmittedVsZero` fails to compile or fails on `ImmediateSync != nil`. Restore. Then make `OmittedOK` of `Connection` return false always: `TestNilProperties` fails. Restore.
- [ ] Step 6: Commit.

### Task 4: Findings and secret names

Files:
- Modify: `internal/model/model.go` (finding kinds), `internal/model/secret.go` (create), `internal/model/model_test.go`
- Modify: `internal/reader/reader.go`, `internal/reader/publisher.go`, `internal/reader/agents.go`, `internal/reader/reader_test.go`
- Create: `internal/reader/secrets.go`, `internal/reader/lab_test.go`, `lab/gotest.sh`
- Modify: `cmd/sqlrepl/main.go` (stderr lines)

Interfaces:
- Consumes: `model.Finding`, paths (Task 3).
- Produces:
  - `model.FindingOutOfScope = "out_of_scope"`, `FindingIncomplete = "incomplete"`, `FindingUnreadable = "unreadable"`, `FindingNote = "note"`.
  - `model.SecretName(kind string, parts ...string) string`: `"SQLREPL_" + kind`, then `"_" + sanitize(p)` per part; `sanitize` upper-cases ASCII letters and replaces every character outside `A-Z0-9` with `_`.
  - In the reader: `(e *exporter) find(kind, path, format string, args ...any)` replaces `warn`, recording each (kind, path, message) once; `type secrets` with `(s *secrets) name(kind string, parts ...string) (string, *model.Finding)`, the finding a `note` when the sanitized name was already given to another source (`raw` key: kind and the parts upper-cased, joined by `\x00`), the name then suffixed `_2`, `_3` in order.
  - Secret names the export writes: the connection of the log reader and snapshot agents `SecretName("SQL", <publisher>, <login>)`; `distributor.publisher_connection` the same; a distribution agent's connection `SecretName("SQL", <subscriber>, <login>)`; `ftp.password_secret` `SecretName("FTP", <ftp address>, <ftp login>)`. Tasks 6, 7 and 10 add the others with the same function.
  - `lab/gotest.sh FILTER PACKAGE...`: needs `MSSQL_SA_PASSWORD` (exits 2 otherwise); URL-encodes it with `python3 -I -c` reading the environment, builds `SQLREPL_TEST_DSN=sqlserver://sa:<encoded>@127.0.0.1:11980?encrypt=disable`, sets `SQLREPL_TEST_LAB=1`, runs `go test -count=1 -v -run "$FILTER" "$@"` and prints only the lines matching `^(=== RUN|--- |ok|FAIL|PASS|panic)`; it never echoes the DSN and never runs under `-x`.
  - In `internal/reader/lab_test.go`: `labDB(t *testing.T, database string) *sql.DB`: skips when `SQLREPL_TEST_LAB` is unset; fails when it is set and `SQLREPL_TEST_DSN` is not; opens the DSN with `database` set as a URL parameter; registers `Close` in `t.Cleanup`. `labRead(t) *model.Config`: reads `Sales` with publisher and distributor both on the lab, through `Export`; Task 5 changes it to return `*Result` from `Read`, and the tests written before follow.
- Kinds of today's warnings: `out_of_scope` for the publisher type, updatable subscriptions (`allow_sync_tran`, `allow_queued_tran`, `update_mode`), `allow_dts`, peer-to-peer bits, non-SQL Server subscribers; `note` for undecoded bits of `options` and `status`, and an article whose publication id is not found; `unreadable` for a source object not found (it can be visibility); `incomplete` for a filter clause without a filter procedure, articles disagreeing on the subscription columns, a missing log reader, snapshot, push or shared agent, a job recorded but missing or without a replication step, and a profile id not found. The snapshot publication and pull subscription warnings stay as they are until Tasks 6 and 10 remove them; give them `out_of_scope` meanwhile.

- [ ] Step 1: Write the tests. In `internal/model`: `TestSecretName`: `SecretName("SQL", "repllab", "distributor_admin") == "SQLREPL_SQL_REPLLAB_DISTRIBUTOR_ADMIN"`, `SecretName("SQL", `PUB\INST`, "repl.user") == "SQLREPL_SQL_PUB_INST_REPL_USER"`, `SecretName("WIN", `DOMAIN\svc`) == "SQLREPL_WIN_DOMAIN_SVC"`. In `internal/reader`: `TestSecretRegistry`: `name("SQL","a_b","c")` and `name("SQL","A_B","c")` give one name and no finding; then `name("SQL","a","b_c")` gives `SQLREPL_SQL_A_B_C_2` and a `note` finding whose message names both sources. `TestFindOnce`: two identical `find` calls give one finding, two with different paths give two. In `lab_test.go`: `TestReadLabSales`: on the lab, `Version == 2`, two publications `SalesPub` and `SalesRef`, `Findings` empty (the lab is complete and in scope; the export of 2026-11-11 had no warning), every `password_secret` in the config (none on the lab, where every connection is `windows`) matches `^SQLREPL_[A-Z0-9_]+$`.
- [ ] Step 2: Run `go test -count=1 -v -run '^TestSecretName$' ./internal/model` and `go test -count=1 -v -run '^(TestSecretRegistry|TestFindOnce)$' ./internal/reader`. Expected: compile failures.
- [ ] Step 3: Implement. In the CLI, each finding goes to stderr as `finding: <kind>: <path>: <message>`.
- [ ] Step 4: Run the Step 2 commands. Expected: 1 and 2 `--- PASS`. Then, in one shell with the password loaded, `lab/gotest.sh '^(TestReadLabSales|TestQueriesParse)$' ./internal/reader`. Expected: 2 `--- PASS`. Then `go test ./...` without a DSN: all pass, the lab tests and `TestQueriesParse` skipped.
- [ ] Step 5: Break step. Drop the `_2` suffix in `secrets.name`: `TestSecretRegistry` fails. Restore. Unset `SQLREPL_TEST_DSN` but keep `SQLREPL_TEST_LAB=1` (run `SQLREPL_TEST_LAB=1 go test -count=1 -v -run '^TestReadLabSales$' ./internal/reader`): the test fails, it does not skip.
- [ ] Step 6: Commit.

### Task 5: Empty configuration and the publisher probe

Files:
- Modify: `internal/reader/reader.go`, `internal/reader/queries.go`, `internal/reader/reader_test.go`, `internal/reader/lab_test.go`
- Modify: `cmd/sqlrepl/main.go`, `README.md` (export section: the empty configuration)

Interfaces:
- Consumes: findings (Task 4).
- Produces:
  - `type Result struct { Config *model.Config }` (Task 11 adds `Facts`), and `func Read(ctx context.Context, src Source) (*Result, error)`, replacing `Export`. `Source.Distributor` may be nil when the probe finds no distributor.
  - `type PublisherProbe struct { Distributor, State string; Standby, Published, MergePublished bool }` and `func Probe(ctx context.Context, publisher *sql.DB, database string) (PublisherProbe, error)`, replacing `DistributorName`. Query `qProbe`, run on the publisher: `ISNULL((SELECT TOP (1) datasource FROM master.dbo.sysservers WHERE srvstatus & 8 <> 0), N'')`, then `state_desc`, `is_in_standby`, `is_published`, `is_merge_published` from `sys.databases WHERE name = @p1`; no row is the error `database %q not found at the publisher`.
  - `func (p PublisherProbe) Start() (empty bool, findings []model.Finding, err error)`, pure, in this order: `State != "ONLINE"` is the error `database is %s` (lower case of the state); `Standby` is the error `database is in standby`; no distributor is `empty` with the `note` "no distributor is configured at the publisher" (path `distributor`); not `Published` is `empty` with the `note` "the database is not enabled for transactional or snapshot publishing" (path `publications`), plus, when `MergePublished`, the `out_of_scope` finding "the database is published for merge replication" (path empty).
  - `Read` on an empty start: `Publisher{Server, Database}`, no publication; when the probe names a distributor and `src.Distributor` is not nil, the distributor section is read as today, except that a publisher absent from `MSdistpublishers` gives `Distributor{Server}` and the `note` "publisher %q is not registered at the distributor" (path `distributor`) instead of today's error. On a non-empty start, that absence stays the error it is today.
  - CLI: `runExport` calls `Probe`; it opens the distributor only when the probe names one (`-distributor` when given, otherwise the probe's name).

- [ ] Step 1: Write `TestStartDecision`, table-driven, over (probe, want empty, want error substring, want finding kinds): `{State: "ONLINE", Distributor: "D", Published: true}` not empty, no error, no finding; `{State: "OFFLINE"}` error `database is offline`; `{State: "RESTORING"}` error `database is restoring`; `{State: "ONLINE", Standby: true, Distributor: "D", Published: true}` error `database is in standby`; `{State: "ONLINE"}` empty, `[note]`; `{State: "ONLINE", Distributor: "D"}` empty, `[note]`; `{State: "ONLINE", Distributor: "D", MergePublished: true}` empty, `[note, out_of_scope]`. In `lab_test.go`, `TestReadLabUnpublishedDatabase`: creates the database `m_empty` (dropped in `t.Cleanup`), reads it with publisher and distributor on the lab; no error, no publication, `Distributor.Server` equals the lab's `@@SERVERNAME` case-insensitively, `Distributor.Database` is `distribution` (`MSdistpublishers` registers the publisher, not a database, so the section is read in full), and the findings are exactly one `note`, at path `publications`. Add `qProbe` to `TestQueriesParse`.
- [ ] Step 2: Run `go test -count=1 -v -run '^TestStartDecision$' ./internal/reader`. Expected: compile failure.
- [ ] Step 3: Implement.
- [ ] Step 4: Run the Step 2 command (expected 1 `--- PASS`), then `lab/gotest.sh '^(TestReadLabUnpublishedDatabase|TestReadLabSales|TestQueriesParse)$' ./internal/reader` (expected 3 `--- PASS`).
- [ ] Step 5: Break step. Make `Start` ignore `Standby`: `TestStartDecision` fails on the standby case. Restore.
- [ ] Step 6: Commit.

### Task 6: Distributor, publisher and publication properties

Files:
- Modify: `internal/model/model.go`, `internal/reader/reader.go`, `internal/reader/publisher.go`, `internal/reader/queries.go`, `internal/reader/reader_test.go`, `internal/reader/lab_test.go`, `README.md`

Interfaces:
- Consumes: `decode.PubOptionAllowPartitionSwitch`, `PubOptionReplicatePartitionSwitch`, `SubscriberType` (Task 2); `SecretName`, the secrets registry (Task 4).
- Produces, model fields and their sources:

| YAML path | Type | Source | Parameter |
|---|---|---|---|
| `publisher.sync_with_backup` | `*bool` | `DATABASEPROPERTYEX(@p1, 'IsSyncWithBackup')` at the publisher | `sp_replicationdboption @optname = 'sync with backup'` |
| `distributor.delete_batch_size_xact`, `delete_batch_size_cmd` | `*int` | `msdb.dbo.MSdistributiondbs.deletebatchsize_xact`, `deletebatchsize_cmd` | `sp_adddistributiondb` |
| `distributor.data_folder`, `data_file`, `log_folder`, `log_file` | `*string` | `sys.master_files` of the distribution database at the distributor, `type` 0 then 1, lowest `file_id` of each, `physical_name` split at its last `/` or `\` (`/var/opt/mssql//DATA` and `distribution.MDF` on the lab, as `distributor-defaults` `D.sp_adddistributiondb.fresh.@data_folder` shows) | `sp_adddistributiondb` |
| `distributor.data_file_size_mb`, `log_file_size_mb` | `*int` | creation only, never read | `sp_adddistributiondb` |
| `distributor.creation_connection` | `*Connection` | creation only, never read | `sp_adddistributiondb @security_mode`, `@login`, `@password` |
| `distributor.admin_password_secret` | `*string` | always `SecretName("SQL", <distributor>, "distributor_admin")` | `sp_adddistributor @password` |
| `distributor.admin_link_security` | `*string` | `sys.linked_logins` of the `repl_distributor` server at the publisher: `uses_self_credential = 1` is `windows`; 0 with `remote_name = N'distributor_admin'` is `sql`; anything else nil with an `unreadable` finding | `sp_adddistributor @security_mode` |
| `distributor.multi_subnet_failover` | `*bool` | `sys.servers.provider_string` of `repl_distributor` at the publisher: `NULL` is false; any other value nil with an `unreadable` finding naming the value (the format the procedure writes is not measured) | `sp_adddistributor @multi_subnet_failover` |
| `distributor.storage_connection_string_secret` | `*string` | `MSdistpublishers.storage_connection_string` not `NULL`: `SecretName("STORAGE", <publisher>)`; `NULL`: nil | `sp_adddistpublisher @storage_connection_string` |
| `publications[*].allow_partition_switch`, `replicate_partition_switch` | `*bool` | `syspublications.options` bits `0x20`, `0x40` | `sp_addpublication` |
| `publications[*].enabled_for_het_sub` | `*bool` | `options` bit `0x4`; true also gives today's `out_of_scope` finding | `sp_addpublication` |
| `publications[*].snapshot.enabled_for_internet` | `*bool` | `syspublications.enabled_for_internet` (read today, now exported); `ftp` is written exactly when it is true | `sp_addpublication` |
| `publications[*].subscriptions[*].subscriber_type` | `*string` | `{dist}.dbo.MSsubscriber_info.type` for `UPPER(publisher) = UPPER(@p1) AND UPPER(subscriber) = UPPER(@p2)`, decoded; not `sql_server` gives an `out_of_scope` finding; no row is nil with an `incomplete` finding | `sp_addsubscription @subscriber_type` |
| `publications[*].subscriptions[*].type` | `*string` | `syssubscriptions.subscription_type`, decoded (`push` until Task 10 reads pull) | `sp_addsubscription @subscription_type` |

- Snapshot publications (`repl_freq = 1`) are in scope: the warning "snapshot publication, out of scope" goes; `type` is `snapshot`.
- `OmittedOK` gains: `Distributor` `data_file_size_mb`, `log_file_size_mb`, `creation_connection` always (creation only), `storage_connection_string_secret` always (nil is "none", the default); `Snapshot` `ftp` when `enabled_for_internet` is false.

- [ ] Step 1: Write the tests. `TestSplitFilePath`: `/var/opt/mssql//DATA/distribution.MDF` gives `/var/opt/mssql//DATA` and `distribution.MDF`; `C:\Data\distribution.MDF` gives `C:\Data` and `distribution.MDF`; `distribution.MDF` gives `""` and itself. `TestReadLabDistributorAndPublications` (lab, values read on 2026-11-11): `data_folder` `/var/opt/mssql//DATA`, `data_file` `distribution.MDF`, `log_folder` `/var/opt/mssql//DATA`, `log_file` `distribution.LDF`, `delete_batch_size_xact` 5000, `delete_batch_size_cmd` 2000, `admin_link_security` `sql`, `multi_subnet_failover` false, `storage_connection_string_secret` nil, `admin_password_secret` `SQLREPL_SQL_REPLLAB_DISTRIBUTOR_ADMIN`, `sync_with_backup` false; on `SalesPub` and `SalesRef` `allow_partition_switch`, `replicate_partition_switch`, `enabled_for_het_sub` and `enabled_for_internet` false; every subscription of both `type` `push` and `subscriber_type` `sql_server`. `TestReadLabSnapshotPublication`: in `Sales`, creates table `dbo.m_t1 (id int PRIMARY KEY, a int)`, publication `m_snap` with `@repl_freq = N'snapshot'`, its snapshot agent with a schedule that never fires (`@frequency_type = 1, @active_start_date = 99991231`), article `m_t1`; cleanup drops the publication then the table. Asserts: `m_snap` has `type` `snapshot`, no finding whose path starts with `publications[m_snap]`, and its article's insert, update and delete commands have mode `SQL` (spec defaults table, snapshot publication). Add every new query to `TestQueriesParse`.
- [ ] Step 2: Run `go test -count=1 -v -run '^TestSplitFilePath$' ./internal/reader`. Expected: compile failure.
- [ ] Step 3: Implement. The publisher-side reads of `repl_distributor` (`sys.servers`, `sys.linked_logins`) go in one query, `qDistributorLink`.
- [ ] Step 4: Run the Step 2 command (1 `--- PASS`), then `lab/gotest.sh '^(TestReadLabDistributorAndPublications|TestReadLabSnapshotPublication|TestReadLabSales|TestQueriesParse)$' ./internal/reader` (4 `--- PASS`).
- [ ] Step 5: Break step. Cut the file path at its first separator instead of its last: `TestSplitFilePath` and `TestReadLabDistributorAndPublications` fail. Restore. (The partition switch bits cannot be broken visibly on the lab, where neither is set; Task 2 pins their values.)
- [ ] Step 6: Update the README's export section (snapshot publications are exported; what `findings` holds). Commit.

### Task 7: Agent jobs, accounts and connections

Files:
- Modify: `internal/model/model.go`, `internal/reader/agents.go`, `internal/reader/queries.go`, `internal/reader/reader_test.go`, `internal/reader/lab_test.go`

Interfaces:
- Consumes: secrets (Task 4).
- Produces:
  - `Agent.JobEnabled *bool` (`job_enabled`): `msdb.dbo.sysjobs.enabled` of the agent's job. Spec "apply" step 3: plan 3 compares it, a snapshot agent being enabled unless the file says otherwise.
  - `Agent.JobLogin *string` (`job_login`): `job_login` of the agent's `MS*_agents` row, `""` for `NULL`. `Agent.JobPasswordSecret *string` (`job_password_secret`): `SecretName("WIN", <job_login>)` when `job_login` is not empty, nil otherwise.
  - `Agent.DistributorConnection *Connection` (`distributor_connection`): for the snapshot agent, from its job step command, switches `-DistributorSecurityMode` (absent means `1`, `windows`) and `-DistributorLogin`; the secret `SecretName("SQL", <distributor>, <login>)` when `sql` (`11-defaults` `D.sp_addpublication_snapshot.transactional.@distributor_*`).
  - `func commandSwitch(cmd, name string) (string, bool)`: finds `-<name>` case-insensitively as a whole token, returns the next token with one level of `[...]` (with `]]` undoubled) or `"..."` removed.
  - `func runAs(proxyID sql.NullInt32, proxyFound bool, credential sql.NullString) (*string, bool)`: no proxy (`proxyID` null) gives `""`, true; a proxy whose row or credential is not visible gives nil, false; otherwise the credential identity, true. On false the reader adds the `unreadable` finding `<path>.run_as` "the job step runs under proxy %d, whose credential this login cannot see".
  - `qJob` reads `sjs.proxy_id`, whether the `sysproxies` row was found, and `sc.credential_identity` without `ISNULL`, plus `sj.enabled`.
- `OmittedOK` gains: `Agent` `job_password_secret` when `job_login` is nil or `""`; `distributor_connection` unless the step before the agent in `parents` has the key `snapshot_agent` or `pull_agent` (Task 10).

- [ ] Step 1: Write the tests. `TestCommandSwitch`: in `-Publisher [REPLLAB] -PublisherDB [Sales] -Distributor [REPLLAB] -Publication [SalesPub] -DistributorSecurityMode 1` (the lab's snapshot command), `DistributorSecurityMode` is `1`, `Distributor` is `REPLLAB`, `DistributorLogin` absent; `-distributorlogin "repl user"` gives `repl user`; `-Publication [a]]b]` gives `a]b`; `-PublisherDB` is not matched by `Publisher`. `TestRunAs`: null proxy gives `""`, true; proxy 3 not found gives nil, false; proxy 3 found with a null credential gives nil, false; proxy 3 with `DOMAIN\svc` gives that, true. `TestReadLabAgents`: on the lab, the log reader, both snapshot agents, `SalesPub`'s distribution agent and the shared agent all have `job_enabled` true, `job_login` `""`, `job_password_secret` nil, `run_as` `""`; both snapshot agents have `distributor_connection.security` `windows`; the log reader and the distribution agents have `distributor_connection` nil.
- [ ] Step 2: Run `go test -count=1 -v -run '^(TestCommandSwitch|TestRunAs)$' ./internal/reader`. Expected: compile failure.
- [ ] Step 3: Implement.
- [ ] Step 4: Run the Step 2 command (2 `--- PASS`), then `lab/gotest.sh '^(TestReadLabAgents|TestReadLabSales|TestQueriesParse)$' ./internal/reader` (3 `--- PASS`).
- [ ] Step 5: Break step. Put `ISNULL(sc.credential_identity, N'')` back and make `runAs` treat an empty credential as found: `TestRunAs` fails on the null credential case. Restore.
- [ ] Step 6: Commit.

### Task 8: Articles, filters and synchronization views

Files:
- Modify: `internal/reader/publisher.go`, `internal/reader/queries.go`, `internal/reader/syncview.go` (create), `internal/reader/reader_test.go`, `internal/reader/lab_test.go`

Interfaces:
- Produces:
  - `func checkSyncView(definition, clause string, columns []string) []string`: the list of problems, empty when the view matches. The format, read on the lab on 2026-11-11 (`OBJECT_DEFINITION` of `SYNC_Customer`, `syncobj_0x3939303644423539`):

    ```
    create view [dbo].[SYNC_Customer]as select  [CustomerID],[Name],[Country]  from  [dbo].[Customer]  where HAS_PERMS_BY_NAME('[dbo].[Customer]', 'OBJECT', 'SELECT')= 1  and (Country = 'FR')
    ```

    The check, after collapsing every run of whitespace to one space and trimming: the column list is the text between the first ` select ` and the first ` from `, split on `,`, each item unquoted (`[a]]b]` is `a]b`); it must equal `columns` in order. The text after the last `= 1` must be empty when `clause` is empty, and `and (<clause collapsed>)` otherwise. Problems are worded `"view columns %v, article columns %v"` and `"view filter %q, article clause %q"`; a definition that does not parse gives `"view definition not recognized"`.
  - The reader reads `OBJECT_DEFINITION(a.sync_objid)` and the article's published columns (all columns of the table when `sysarticlecolumns` covers them all) for every table article with a `sync_objid`; a nil definition (not visible) is an `unreadable` finding at `<article path>.sync_object`; problems are `incomplete` findings at the same path.
  - New `incomplete` findings, from spec "Filters and views" and "Inputs": a filter procedure whose clause is `NULL` (path `<article path>.filter`); a subscription that lists a subset of the articles of a publication where a subset cannot exist, which is `immediate_sync` true or `sync_method` `concurrent` or `concurrent_c` (spec "Subscriptions"; path `<subscription path>.articles`).
  - `func subsetAllowed(p *model.Publication) bool`.
  - `Destination.Schema` is `""` for a `NULL` `dest_owner`, as the query's `ISNULL` already gives (Task 3).

- [ ] Step 1: Write the tests. `TestCheckSyncView`, cases on the lab's two definitions above: `SYNC_Customer` with clause `Country = 'FR'` and columns `CustomerID, Name, Country`: no problem; same with clause `Country = 'DE'`: one filter problem; same with columns `CustomerID, Name`: one columns problem; `syncobj_0x3939303644423539` (columns `OrderID, CustomerID, Amount`, no clause) with an empty clause: no problem, with clause `Amount > 0`: one filter problem; `not a view`: `view definition not recognized`. `TestSubsetAllowed`: false for `immediate_sync` true, false for `concurrent` and `concurrent_c`, true for `native` and `database_snapshot` without `immediate_sync`. `TestReadLabArticles`: on the lab, no finding; `Customer`'s `sync_object` is `dbo.SYNC_Customer`, its `destination.schema` `dbo`; the lab's other two table articles have no `sync_object` (generated views).
- [ ] Step 2: Run `go test -count=1 -v -run '^(TestCheckSyncView|TestSubsetAllowed)$' ./internal/reader`. Expected: compile failure.
- [ ] Step 3: Implement.
- [ ] Step 4: Run the Step 2 command (2 `--- PASS`), then `lab/gotest.sh '^(TestReadLabArticles|TestReadLabSales|TestQueriesParse)$' ./internal/reader` (3 `--- PASS`).
- [ ] Step 5: Break step. Compare the column lists as sets instead of in order, and add a case with `Name, CustomerID, Country`: it must report a problem, and the set comparison makes `TestCheckSyncView` fail. Keep the case, restore the order.
- [ ] Step 6: Commit.

### Task 9: Every profile of the distributor

Files:
- Modify: `internal/reader/reader.go`, `internal/reader/reader_test.go`, `internal/reader/lab_test.go`

Interfaces:
- Produces: `func selectProfiles(profiles map[int]profileRow, params map[int]map[string]string) []model.AgentProfile`, pure: every user-defined profile (`type = 1`) of an in-scope agent type (1, 2, 3), whether or not an agent uses it, sorted by agent type then name. `collectProfiles` calls it; the "used or default" condition goes. Which agents use a profile is a fact (Task 11).

- [ ] Step 1: Write `TestSelectProfiles`: from four rows (a system profile of type 3, a user profile of type 3 used by no agent, a user profile of type 9, a user profile of type 1 marked default), the result is the two user profiles of types 1 and 3, type 1 first. `TestReadLabProfiles`: on the lab, `agent_profiles` holds `distribution/lab-distrib` with description `lab profile`, default false, `parameters["-CommitBatchSize"] == "200"` (`lab/setup.sql`). On 2026-11-11 this profile was missing from the export, which kept only used profiles: no lab agent is bound to it (`MSdistribution_agents.profile_id` 4 for both agents).
- [ ] Step 2: Run `go test -count=1 -v -run '^TestSelectProfiles$' ./internal/reader`. Expected: compile failure.
- [ ] Step 3: Implement.
- [ ] Step 4: Run the Step 2 command (1 `--- PASS`), then `lab/gotest.sh '^(TestReadLabProfiles|TestReadLabSales)$' ./internal/reader` (2 `--- PASS`).
- [ ] Step 5: Break step. Put back the "used or default" condition: both tests fail. Restore.
- [ ] Step 6: Commit.

### Task 10: Pull subscriptions and subscriber connections

Files:
- Modify: `internal/model/model.go`, `internal/reader/publisher.go`, `internal/reader/agents.go`, `internal/reader/queries.go`, `internal/reader/reader.go`, `internal/reader/reader_test.go`, `internal/reader/lab_test.go`
- Create: `internal/reader/testdata/pull-setup.sql`, `internal/reader/testdata/pull-teardown.sql`
- Modify: `cmd/sqlrepl/main.go`, `cmd/sqlrepl/conn_test.go`, `README.md`

Interfaces:
- Consumes: `decode.SubscriptionType` (Task 2), `commandSwitch`, `runAs` (Task 7), secrets (Task 4).
- Produces:
  - `Source.Subscribers map[string]*sql.DB`, keyed by `strings.ToUpper` of the server name, each connected to `master` of that server.
  - Model: `Subscription.PullAgent *PullAgent` (`pull_agent`); `PullAgent{ DistributionAgent (inline); Distributor *string; AltSnapshotFolder *string; WorkingDirectory *string; UseFTP *bool (use_ftp); EnabledForSyncmgr *bool (enabled_for_syncmgr); Description *string }`.
  - Sources, at the subscriber, following the join of `sp_helppullsubscription` (`stored-procedures/sp_helppullsubscription.sql:94-176`): `[<subdb>].dbo.MSreplication_subscriptions` (`subscription_type = 1`, `UPPER(publisher) = UPPER(<publisher>)`, `publisher_db`, `publication`; `independent_agent`, `immediate_sync`, `description`, `agent_id` the job id), `[<subdb>].dbo.MSsubscription_properties` (`distributor`, `distributor_security_mode`, `distributor_login`, `alt_snapshot_folder`, `working_directory`, `use_ftp`, `enabled_for_syncmgr`, `job_login`, `job_step_uid`, `dts_package_name`), and the job in the subscriber's `msdb` through `qJob` (step command switches `-SubscriberSecurityMode`, `-SubscriberLogin` give `connection`). At the distributor, the agent row of `MSdistribution_agents` with `subscription_type = 1` gives `profile`, `subscription_streams`, `memory_optimized`. `<subdb>` is spliced as `quoteName(<database>)` through a `{subdb}` placeholder, as `{dist}` is.
  - Secrets: `connection` `SecretName("SQL", <subscriber>, <login>)`, `distributor_connection` `SecretName("SQL", <distributor>, <login>)`, `job_password_secret` as Task 7.
  - Findings: a pull subscription whose subscriber has no connection: `pull_agent` nil, `unreadable` "subscriber %s is not connected: pass -server %s=ADDRESS"; no `MSreplication_subscriptions` row at a connected subscriber: `pull_agent` nil, `incomplete`; a subscriber row of type 2: `out_of_scope` (anonymous, `08-pull` `P1.omitted`); `independent_agent` or `immediate_sync` at the subscriber different from the publication: `incomplete` (these are copies, `sp_addpullsubscription`; the model keeps the publication's); `dts_package_name` set: `out_of_scope`. The warning "pull subscription, out of scope, not exported" goes.
  - `OmittedOK` gains: `Subscription` `pull_agent` when `type` is `push`; `distribution_agent` also when `type` is `pull`.
  - CLI: `-server NAME=ADDRESS`, repeatable (`type serverFlags map[string]string` keyed by upper-case `NAME`; a second entry for the same name in any case is the error `server %s given twice`; an empty name or address is an error). `-distributor`, when absent, is looked up in it before falling back on the probe's name. Every `-server` entry that is neither the publisher's nor the distributor's address is opened to `master` before the read and passed in `Source.Subscribers`; a connection failure is an error.

- [ ] Step 1: Write the tests. `TestServerFlags` (`cmd/sqlrepl`): `repllab=tcp:127.0.0.1,11980` then lookup of `REPLLAB` finds the address; `a=x` then `A=y` is an error; `=x` and `a=` are errors. `TestSubscriberQueryQuotesDatabase` (`internal/reader`): the subscriber query for database `m sub]1` contains `[m sub]]1].dbo.MSreplication_subscriptions` and no `{`. `testdata/pull-setup.sql`, from `lab/campaign/08-pull.sh:126-158`: in `Sales` table `dbo.m_pt1 (id int PRIMARY KEY, a int)`; database `m_psub`; publication `m_pp` (`@allow_pull = N'true'`, `@independent_agent = N'true'`, `@immediate_sync = N'false'`, `@status = N'active'`), its snapshot agent with the never-firing schedule, article `m_pt1`; `sp_addsubscription @subscription_type = N'pull'`, `@sync_type = N'automatic'`, `@article = N'all'` to `m_psub`; in `m_psub`, `sp_addpullsubscription @subscription_type = N'pull'`, then `sp_addpullsubscription_agent` with `@distributor = @@SERVERNAME`, both security modes 1, no frequency parameter (no schedule, `11-defaults` `D.sp_addpullsubscription_agent.pull.@frequency_type`). `testdata/pull-teardown.sql`, in the order of `08-pull` `P3.subscriber-first`: `sp_droppullsubscription` in `m_psub`, `sp_dropsubscription @article = N'all'` in `Sales`, `sp_droppublication`, `DROP DATABASE m_psub`, `DROP TABLE dbo.m_pt1`, each in its own `TRY` so that the rest runs. `TestReadLabPullSubscription`: runs the setup (teardown in `t.Cleanup`), reads `Sales` with `Subscribers` keyed `"REPLLAB"` from a connection opened for the flag key `repllab` (lower case, Review Focus 1); `m_pp`'s subscription to `m_psub` has `type` `pull`, `distribution_agent` nil, `pull_agent` with `job_enabled` true, `connection.security` `windows`, `distributor_connection.security` `windows`, `distributor` equal to the lab's `@@SERVERNAME` case-insensitively, `use_ftp` false, `schedules` empty and non-nil, `job_login` `""`; no finding under `publications[m_pp]`. `TestReadLabPullSubscriberNotConnected`: same setup, read with no subscriber; `pull_agent` nil and exactly one `unreadable` finding at `publications[m_pp].subscriptions[REPLLAB/m_psub].pull_agent`.
- [ ] Step 2: Run `go test -count=1 -v -run '^TestServerFlags$' ./cmd/sqlrepl` and `go test -count=1 -v -run '^TestSubscriberQueryQuotesDatabase$' ./internal/reader`. Expected: compile failures.
- [ ] Step 3: Implement.
- [ ] Step 4: Run the Step 2 commands (1 and 1 `--- PASS`), then `lab/gotest.sh '^(TestReadLabPullSubscription|TestReadLabPullSubscriberNotConnected|TestReadLabSales|TestQueriesParse)$' ./internal/reader` (4 `--- PASS`). Then check that the teardown left nothing: `sql_value` of the count of `m_` rows in `Sales.dbo.syspublications`, `sys.databases` and `msdb.dbo.sysjobs` (name containing `-m_`) is 0.
- [ ] Step 5: Break step. Key `Subscribers` lookups with the stored name as is: `TestReadLabPullSubscription` fails (the stored `REPLLAB` does not find a lower-case key, or the reverse). Restore.
- [ ] Step 6: Update the README (pull subscriptions are exported; `-server`). Commit.

### Task 11: Observed runtime facts

Files:
- Create: `internal/state/facts.go`, `internal/state/facts_test.go`, `internal/reader/facts.go`
- Modify: `internal/reader/reader.go`, `internal/reader/queries.go`, `internal/reader/reader_test.go`, `internal/reader/lab_test.go`, `cmd/sqlrepl/main.go`, `README.md`

Interfaces:
- Consumes: `Read`, `Result` (Task 5), the agent rows (Tasks 7, 10).
- Produces, in `internal/state` (JSON keys in snake case, as written):

```go
type Facts struct {
	ReadAt        string              `json:"read_at"` // distributor SYSDATETIME()
	Publications  []PublicationFacts  `json:"publications"`
	Subscriptions []SubscriptionFacts `json:"subscriptions"`
	Agents        []AgentFacts        `json:"agents"`
	ProfileUses   []ProfileUse        `json:"profile_uses"`
}
type PublicationFacts struct {
	Name               string         `json:"name"`
	ImmediateSyncReady bool           `json:"immediate_sync_ready"`
	LastGeneration     string         `json:"last_generation,omitempty"`
	Articles           []ArticleFacts `json:"articles"`
}
type ArticleFacts struct {
	Name   string `json:"name"`
	Active bool   `json:"active"`
}
type SubscriptionFacts struct {
	Publication string            `json:"publication"`
	Subscriber  string            `json:"subscriber"`
	Database    string            `json:"database"`
	Rows        []SubscriptionRow `json:"rows"`
}
type SubscriptionRow struct {
	Article           string `json:"article"`
	PublisherStatus   int    `json:"publisher_status"`
	DistributorStatus *int   `json:"distributor_status"`
}
type AgentFacts struct {
	Kind        string      `json:"kind"` // log_reader, snapshot, distribution, pull_distribution
	Publication string      `json:"publication,omitempty"` // ALL for a shared agent
	Subscriber  string      `json:"subscriber,omitempty"`
	Database    string      `json:"database,omitempty"`
	AgentID     int         `json:"agent_id"`
	Job         *JobState   `json:"job"` // nil: the job's server is not connected
	LastHistory *HistoryRow `json:"last_history,omitempty"`
	LastFailure *HistoryRow `json:"last_failure,omitempty"`
}
type JobState struct {
	Exists  bool `json:"exists"`
	Enabled bool `json:"enabled"`
	Running bool `json:"running"`
}
type HistoryRow struct {
	Time      string `json:"time"`
	RunStatus int    `json:"runstatus"`
	Comments  string `json:"comments"`
	ErrorText string `json:"error_text,omitempty"`
}
type ProfileUse struct {
	Profile     string `json:"profile"`
	AgentType   string `json:"agent_type"`
	PublisherDB string `json:"publisher_db"`
	Publication string `json:"publication,omitempty"`
	Subscriber  string `json:"subscriber,omitempty"`
	Database    string `json:"database,omitempty"`
}
```

- Sources, each with the trap it avoids:
  - `ImmediateSyncReady`: `syspublications.immediate_sync_ready` (spec "Inputs").
  - `LastGeneration`: the latest `time` of `{dist}.dbo.MSsnapshot_history` with `runstatus = 2` for the publication's snapshot agent id.
  - `Active`: bit `0x1` of `sysarticles.status` (spec "What is not compared": set by the generation, never a witness of a delivery). Schema articles have no such bit and are listed with `Active` false.
  - `PublisherStatus`: `syssubscriptions.status` per article, `srvid >= 0`. `DistributorStatus`: `{dist}.dbo.MSsubscriptions.status` of the subscription's own rows (`subscriber_id >= 0`, joined to `MSpublications` and `MSarticles` on publisher id, database and ids, the subscriber through `{servers}`), never the rows of the publication or the virtual subscribers (spec "Inputs": the `-1` row's window moves at every run; status 3 is read here, never in `syssubscriptions`, `O18`). Nil when the row is missing.
  - `Job`: `msdb.dbo.sysjobs.enabled`, and running when the job's `sysjobactivity` row of the latest `syssessions` session has a `start_execution_date` and no `stop_execution_date`; at the distributor for every agent but a pull agent, at the subscriber for it. A job id the replication tables keep without a job is `Exists` false (`CLAUDE.md`).
  - `LastHistory`, `LastFailure`: the latest row, and the latest with `runstatus = 6`, of `MSlogreader_history`, `MSsnapshot_history` or `MSdistribution_history` for the agent id, with `MSrepl_errors.error_text` through `error_id`. A shared agent is the agent row with `publication = N'ALL'`.
  - `ProfileUses`: every row of `MSlogreader_agents`, `MSsnapshot_agents` and `MSdistribution_agents` at the distributor, all databases, whose `profile_id` is a user-defined profile (`MSagent_profiles.type = 1`); this is the only part of the facts not limited to the publication database (spec "Shared distributor objects").
- Whether a snapshot is pending is not a fact of its own: plan 3 derives it from `PublisherStatus` 1 and an inactive subscribed article, by the definition of spec "Inputs". A generated, undelivered snapshot is not read (campaign item 14 has not measured the test).
- `Result.Facts *state.Facts`; an empty configuration gives empty lists, not nil. `func jobState(exists bool, enabled int, start, stop sql.NullTime) state.JobState`, pure.
- CLI: `sqlrepl export -facts <path>` writes `json.MarshalIndent(facts, "", "  ")` to the path. Without the flag nothing about facts is written, and the YAML on standard output is unchanged.

- [ ] Step 1: Write the tests. `TestFactsJSONKeys` (`internal/state`): a `Facts` with one of each element marshals to JSON whose keys are exactly those of the tags above, `distributor_status` written as `null` when nil. `TestJobState`: no job gives `Exists` false; start set and stop null gives `Running` true; both set gives `Running` false; `enabled` 0 gives `Enabled` false. `TestReadLabFacts`: on the lab, `SalesPub` has `immediate_sync_ready` true and a `last_generation`; `SalesRef` false; every row of both subscriptions to `SalesSub` has `publisher_status` 2 and `distributor_status` 2 (state `start.sh` waits for); `Customer` is active; the log reader and the two distribution agents have `job.exists`, `job.enabled` and `job.running` true (all three ran continuously on 2026-11-11); `profile_uses` is empty (`lab-distrib` is bound to no agent, Task 9).
- [ ] Step 2: Run `go test -count=1 -v -run '^TestFactsJSONKeys$' ./internal/state` and `go test -count=1 -v -run '^TestJobState$' ./internal/reader`. Expected: compile failures.
- [ ] Step 3: Implement.
- [ ] Step 4: Run the Step 2 commands (1 and 1 `--- PASS`), then `lab/gotest.sh '^(TestReadLabFacts|TestReadLabSales|TestQueriesParse)$' ./internal/reader` (3 `--- PASS`). Then, in one shell, build `sqlrepl`, run the export of `Sales` with `-facts` into the scratch directory twice, and check that the two YAML outputs are byte-identical while both facts files parse with `python3 -I -m json.tool`.
- [ ] Step 5: Break step. Read `DistributorStatus` joined by publication only, without the subscriber: `TestReadLabFacts` fails (virtual subscriber rows mix in, or a row is duplicated). Restore.
- [ ] Step 6: Update the README (`-facts`, what the file holds, that it is not configuration). Commit.

### Task 12: Parameter mapping and the completeness of the export

Files:
- Create: `internal/model/parameters.go`, `internal/model/parameters_test.go`
- Modify: `internal/reader/lab_test.go`

Interfaces:
- Consumes: `lab/results/2022/17-parameters.txt` (Task 1), the model of Tasks 3 to 10, `NilProperties` (Task 3).
- Produces:

```go
type ParamKind string

const (
	ParamField        ParamKind = "field"         // read by the export, compared by plan 3
	ParamCreationOnly ParamKind = "creation_only" // in the model, passed at creation, never read
	ParamExcluded     ParamKind = "excluded"      // not in the model
)

type ParamMapping struct {
	Procedure string    // sp_addarticle
	Parameter string    // @schema_option
	Kind      ParamKind
	Paths     []string  // patterns, e.g. publications[*].articles[*].schema_options; empty when excluded
	Reason    string    // required for creation_only and excluded; the source (11-defaults row, Learn, measurement)
}

var Parameters []ParamMapping
```

- The rules that decide each parameter. A parameter that none of them covers, and that the fields of Tasks 3 to 10 do not hold, is a gap: stop and report it, do not invent a field.
  - Identity of the object (`@publication`, `@article`, `@subscriber`, `@destination_db`, `@subscriber_db`, `@publisher_db`, `@dbname`, `@database`, `@distributor`, `@profile_name`, `@agent_type`, `@agent_id`, `@profile_id` where it names the profile): `field`, the key field of the object.
  - `@frequency_*` and `@active_*` of the agent procedures and of `sp_addsubscription`: `field`, the `schedules` of the agent they create.
  - Passwords: `field` on the secret name the export writes; `creation_only` where the server stores nothing (`sp_adddistributiondb @password`, `sp_addsubscription @password`, `@mediapassword`).
  - Call flags and output parameters (`@force_invalidate_snapshot`, `@force_reinit_subscription`, `@change_active`, `@refreshsynctranprocs`, `@refresh_synctran_procs`, `@ignore_distributor`, `@internal`, `@from_scripting`, `@encrypted_password`, `@encrypted_distributor_password`, `@artid`, `@distribution_jobid`, `sp_add_agent_profile @profile_id`, `@reserved`, `@createmode`): `excluded`, "a flag or an output of the call, not configuration".
  - `@publisher` of every procedure but `sp_adddistpublisher`, `@use_default_datatypes`, `@thirdparty_flag`, `@publisher_type`, `@subscriber_provider`, `@subscriber_datasrc`, `@subscriber_location`, `@subscriber_provider_string`, `@subscriber_catalog`: `excluded`, non-SQL Server publishers or subscribers (Learn; reported as `out_of_scope` when set).
  - `@job_security_mode`: `excluded`, Managed Instance only (41989, `07-changes`).
  - `@offloadagent`, `@offloadserver`: `excluded`, no longer supported (21698, `08-pull` `P2.offload_*`).
  - `@allow_sync_tran`, `@allow_queued_tran`, `@autogen_sync_procs`, `@conflict_policy`, `@centralized_conflicts`, `@conflict_retention`, `@queue_type`, `@qreader_job_name`, `@update_mode`, the peer-to-peer parameters, `@allow_dts` and every `@dts_package_*`: `excluded`, out of scope (updatable, queued, peer-to-peer, DTS), reported as `out_of_scope` when set.
  - `@auto_identity_range`, `@pub_identity_range`, `@identity_range`, `@threshold`, `@identityrangemanagementoption`: `excluded`, identity range management serves updatable subscriptions and stores no row by default (`11-defaults` `no-row`).
  - Not stored and not needed (`@taskid`, `@restricted`, `@add_to_active_directory`, `@distribution_job_name`, push `@enabled_for_syncmgr`, `sp_addpullsubscription_agent @distribution_db`, its `@ftp_*` (inserted as `NULL`, `stored-procedures/sp_addpullsubscription_agent.sql:754-767`, `08-pull` `P2.ftp_*`), `@publication_type`, `sp_addpullsubscription @independent_agent`, `@immediate_sync`, `@subscription_type`): `excluded`, with the source; the last four are copies of the publication's values that the reader checks (Task 10).
  - `@status` of `sp_addsubscription`: `excluded`, the stored status is runtime state, read as a fact. `@status` of `sp_addarticle`: `field`, `insert_column_names` and `parameterized` (the `active` bit is a fact).
  - `@optional_command_line`: `field`, the agent's `command` (shown, never compared, spec "What is not compared").
  - `@backupdevicetype`, `@backupdevicename`, `@fileidhint`, `@unload`, `@subscriptionlsn`, `@data_file_size`, `@log_file_size`, `sp_adddistributiondb @security_mode`, `@login`: `creation_only` (`11-defaults`, `distributor-defaults` `no-column`). This task adds the model fields they need, `Subscription.Backup *BackupInitialization` (`backup`; `DeviceType`, `DeviceName *string`, `MediaPasswordSecret`, `PasswordSecret *string`, `FileIDHint *int`, `Unload *bool`) and `Subscription.LSN *string` (`lsn`, hexadecimal), and `OmittedOK` for both, always.
  - `@optname`, `@value` of `sp_replicationdboption`: `field`, `publisher.sync_with_backup` for `sync with backup`; `publish` is implied by a file with publications; the other options are not this database's configuration (Reason says so).
- Tests:
  - `TestParametersCovered`: for each of `lab/results/2019`, `2022`, `2025` whose `17-parameters.txt` exists (2022 must), every `R|<procedure>.<parameter>|` row has exactly one entry in `Parameters`; every entry names a parameter listed in at least one of the files; `Reason` is not empty for `creation_only` and `excluded`; `Paths` is not empty for `field` and `creation_only` and empty for `excluded`. On 2022 alone: 316 entries.
  - `TestParameterPathsResolve`: every pattern of `Paths` resolves through the model types by YAML tag (`[*]` a slice element, inline structs flattened, a map accepting any key after it).
  - `TestReadLabExportsEveryProperty`: on the lab, `NilProperties` of the export of `Sales`, minus the paths named by a finding or under one, is empty; then, in the same test (no subtest), with the pull setup of Task 10 applied (teardown in `t.Cleanup`), still empty.

- [ ] Step 1: Write the three tests.
- [ ] Step 2: Run `go test -count=1 -v -run '^(TestParametersCovered|TestParameterPathsResolve)$' ./internal/model`. Expected: compile failure.
- [ ] Step 3: Write `Parameters` and the fields of the `creation_only` rule above.
- [ ] Step 4: Run the Step 2 command (2 `--- PASS`), then `lab/gotest.sh '^TestReadLabExportsEveryProperty$' ./internal/reader` (1 `--- PASS`). A path `NilProperties` reports is a property the export does not write: fix the reader, not the test.
- [ ] Step 5: Break step. Delete the entry of `sp_addarticle @schema_option`: `TestParametersCovered` fails naming it. Restore. Change one path to `publications[*].articles[*].schema_option` (singular): `TestParameterPathsResolve` fails. Restore.
- [ ] Step 6: Commit.

### Task 13: Listing on 2019 and 2025, and the documentation

Files:
- Create: `lab/results/2019/17-parameters.txt`, `lab/results/2025/17-parameters.txt` (when the version runs)
- Modify: `internal/model/parameters.go`, `lab/README.md`, `CLAUDE.md`, `README.md`

Interfaces:
- Consumes: `lab/campaign/17-parameters.sql` (Task 1), `TestParametersCovered` (Task 12).

- [ ] Step 1: In one shell: load the password, `lab/start.sh 2019`, `lab/campaign.sh 2019 lab/campaign/17-parameters.sql`; then `lab/start.sh 2025`, `lab/campaign.sh 2025 lab/campaign/17-parameters.sql`; then `lab/start.sh 2022`. `start.sh` recreates `repllab` each time, which loses nothing: the lab has no state of its own. Record each total. When `start.sh` or a guard fails on a version (the `export` guard runs this plan's export against that version, and may meet a column or a behavior 2022 does not have), record the failure and its detail in `lab/README.md` as open for the support claim of that version, and do not change the export in this task.
- [ ] Step 2: Run `go test -count=1 -v -run '^TestParametersCovered$' ./internal/model`. Expected: 1 `--- PASS` if the versions add nothing; otherwise it fails naming each parameter only 2019 or 2025 has. Map each by the rules of Task 12 (a parameter no rule covers is reported, not invented), rerun, 1 `--- PASS`.
- [ ] Step 3: Break step. Delete the 2025 file's last parameter row and fix its `TOTAL`: if that parameter exists only on 2025, `TestParametersCovered` fails on the now unlisted entry; otherwise it still passes, which is correct. Restore the file from git.
- [ ] Step 4: Update `lab/README.md` (the counts per version), `README.md` (export: findings, facts, `-server`, the empty configuration, the format version 2) and `CLAUDE.md` (status: plan 2 done; architecture: `internal/state`, `Result`, pointers mean omitted, finding kinds, secret names, `lab/gotest.sh`; the new traps: the view format, `MSsubscriptions` read per subscription, the pull subscriber join).
- [ ] Step 5: Run the whole suite on the lab, in one shell: `lab/gotest.sh '.' ./...`. Expected: no `--- FAIL`, no `--- SKIP`. Then `go build ./cmd/sqlrepl && go vet ./... && test -z "$(gofmt -l .)" && go test ./...`.
- [ ] Step 6: Stop the lab (`SHUTDOWN WITH NOWAIT` through `sql`), report `podman ps`. Commit.

## What plan 3 receives

- `reader.Read(ctx, Source) (*Result, error)` with `Result.Config *model.Config` and `Result.Facts *state.Facts`; `model.Load(io.Reader) (*Config, error)` for the desired file.
- In a desired file, nil is "omitted, take the default"; in a read configuration, nil appears only where `OmittedOK` allows it or a finding names the path (`TestReadLabExportsEveryProperty`). An `unreadable` finding marks a value plan 3 must not compare.
- `out_of_scope` findings make plan 3 refuse the database; `incomplete` ones are states it repairs.
- `model.Parameters`: for each procedure parameter, the field plan 3 passes it from, or why it passes nothing.
- Defaults that depend on the file and not on the server, for plan 3's normalization: `job_enabled` true for a snapshot agent (spec "apply" step 3); `schema_options`, commands and destination owner by context (spec "Omitted properties").

## Self-review

- Spec coverage. "Extending the model and the export": empty configuration (Task 5), pull subscriptions at publisher and subscriber (Task 10), snapshot publications (Task 6), every profile and its use (Tasks 9, 11), the facts with the distribution agent state (Task 11), the view definition (Task 8), NULL credential reads (Task 7), every parameter mapped (Tasks 1, 12, 13), secret names (Tasks 4, 6, 7, 10, 12). "Inputs": findings split (Task 4), errors never read as absence (Task 5), `MSsubscriptions` status 3 and the log reader state (Task 11). "Blocking": codes 5 and 6 (Task 2). "apply" step 3: `job_enabled` (Task 7). "Filters and views": the three reader warnings (Tasks 4, 8). Left to plan 3 by the controller: secrets loading, normalization, the comparison.
- Open after this plan: the shared pull agent of a publication without an independent agent is read by `sp_helppullsubscription`'s join and not measured on the lab; `multi_subnet_failover` true and `admin_link_security` other than the two measured forms are reported `unreadable`; the 2019 and 2025 listings depend on Task 13 Step 1.
