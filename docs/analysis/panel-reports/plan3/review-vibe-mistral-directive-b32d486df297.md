# Review of `2026-11-12-sqlrepl-3-planner.md` (commit `c8c06e3`)

Reviewed against the spec, `CLAUDE.md`, plan 2's "What plan 3 receives", the code of
`internal/{model,reader,state,decode}` and `cmd/sqlrepl`, and the measured tables of
`lab/results/2022/`, `lab/README.md` and `lab/campaign/`. Statements marked "ran" were
executed on `repllab` (127.0.0.1:11980) on objects named `rv_q7x3kd*` that I created and
removed (see the end).

## Verified by running

1. **The plan's encoder spec produces a refused call for every `schema_option` change.**
   Task 8 defines the encoders as T-SQL literals and says "`@schema_option` `0x` and 16
   hex digits of `EncodeSchemaOptions`", and the `Param` doc shows `0x0000000000030073`
   as an example literal. For `sp_changearticle` the parameter is `@value`
   (`nvarchar(255)`), and the measured campaign passes it as the *string* `N'0x…'`
   (`02-matrix.sql` line 62, rows `A12`/`A13`). I ran both forms on my
   `rv_q7x3kd_p` (ready, `immediate_sync`, subscription at status 2), each in a
   rolled-back transaction:
   `EXEC sp_changearticle …, @property = N'schema_option', @value = 0x0000000000030073, @force_invalidate_snapshot = 1, @force_reinit_subscription = 1`
   returned `Msg 21805 … '' is not a valid value for the '@value' parameter. The value
   must be an integer`, `@@TRANCOUNT` left at 1 (the doomed-transaction trap of lab
   row 11); the same call with `@value = N'0x0000000000030073'` returned 0, printed
   "Invalidated the existing snapshot… Reinitialized subscription(s)", set
   `immediate_sync_ready` 1 to 0 and the operated article's row 2 to 1, exactly as
   `15-snapshot-scope C.*.schema_option` records. The bare hex literal is correct only
   for `sp_addarticle.@schema_option` (a `binary(8)` parameter); the plan never says
   that the two procedures encode the same model value differently, and
   `TestEncodeValues` ("one case each" of the listed encodings) has no case that could
   fail if `sp_changearticle`'s `@value` were rendered as the bare hex. An implementer
   following Task 8 verbatim generates a call the server refuses with 21805 on every
   `schema_option` change, discovered only when a convergence test or a real `apply`
   runs one.

2. **The same gap for `sp_changepublication @value` of `replicate_ddl`: `N'false'` is
   refused, `N'0'` works.** Task 8 says "booleans `N'true'`/`N'false'`" with encoders
   keyed `<procedure>.@<param>`; the cost table has an entry
   `publications[*].replicate_ddl | to_false; to_true | sp_changepublication replicate_ddl`
   citing `P05`/`P06`, which the campaign ran with `@value = N'0'` (`02-matrix.sql`
   line 24). I ran every boolean property of `sp_changepublication` on
   `rv_q7x3kd_p` with the plan's `N'true'`/`N'false'` form, each in its own
   TRY/CATCH transaction: all were accepted (`allow_drop`, `allow_partition_switch`,
   `replicate_partition_switch`, `allow_subscription_copy`,
   `allow_initialize_from_backup`, `allow_push`, `allow_pull`, `allow_anonymous`,
   `immediate_sync`, `independent_agent`, `enabled_for_het_sub`, `status`,
   `retention`) **except** `replicate_ddl = N'false'`, which raised
   `Msg 245 … Conversion failed when converting the nvarchar value 'false' to data type int`,
   leaving `@@TRANCOUNT` at 2; `replicate_ddl = N'0'` and `N'1'` were accepted. So the
   blanket "booleans `N'true'`/`N'false'`" rule is wrong for exactly one property, the
   plan nowhere records that `replicate_ddl`'s `@value` is an integer, and no test in
   Task 8 can catch it. Root cause shared with finding 1: `encoders` keyed by
   `<procedure>.@<param>` cannot express the per-property encodings of `@value`, which
   serves about twenty properties with at least four literal forms (int for
   `retention`/`replicate_ddl`, `N'0x…'` for `schema_option`, `N'true'` for the other
   booleans, plain strings for `sync_method`/`status`/paths).

3. **`TestProcContextsCiteRows` cannot pass with the citation the plan's own table
   gives.** Task 8's `procContexts` table puts `sp_addlogreader_agent` in the group
   "publisher, publication" with source "`12-contexts X.<procedure>.Sales`", and the
   same task's Step 1 defines `TestProcContextsCiteRows` as requiring "every `X.` source
   exists in `12-contexts.txt` or `distributor-defaults.txt` with an `ok` result". In
   `lab/results/2022/12-contexts.txt` the row is
   `R|X.sp_addlogreader_agent.Sales|21831|… msg=The logreader agent already exists…`
   — an error, not `ok` (Sales already had the lab's log reader when the campaign ran;
   the `ok` row for a fresh publication database is `X.sp_addlogreader_agent.m_ctx`).
   Every other `X.` row the table cites is `ok` (`sp_addpublication/article/filter/view/column/subscription/push agent/snapshot agent .Sales`, `sp_add_agent_profile.master`,
   `sp_replicationdboption.master`, `sp_addpullsubscription(_agent).m_ctx`,
   `distributor-defaults X.sp_adddistributor(_db)/sp_adddistpublisher .master`). So as
   written, the plan cites a row its own test rejects; the implementer must silently
   substitute `m_ctx` for `sp_addlogreader_agent`. Cheap to discover (Task 8 Step 4),
   but it is a test that cannot pass as written.

## Concluded by reading

Hypotheses, not confirmed defects.

1. **A hand-written declared schedule with omitted date fields would send
   `@active_start_date = 0`.** R22 compares a declared schedule "in full" except
   `name`, and the schedule-change call passes "every `@frequency_*` and `@active_*`
   parameter of the declared schedule". `Schedule.StartDate` etc. are plain ints with
   `omitempty`, so a file declaring `frequency: daily` without `start_date` holds 0,
   the diff sees 0 against the current 20261112, and the generated call carries
   `@active_start_date = 0`. No campaign row measures 0 (the scripts always use
   99991231; `AGT.sp_changepublication_snapshot.active_end_date` shows 14278 for an
   inconsistent pair). Export-then-plan is safe (the export always writes the dates,
   and I confirmed the live `Sales` export round-trips through `model.Load` with zero
   nil properties), so this only affects hand-written files — but there it is exactly
   the "non-empty plan for an unchanged configuration" class of defect, or a refused
   call.

2. **The `encoders`/`neverPassed` tables keyed `<procedure>.@<param>` structurally
   cannot cover `sp_changepublication`/`sp_changearticle` `@value`** (the root cause
   of findings 1 and 2 above, stated as the design gap: the plan says
   `TestEncodersCoverParameters` checks "every `field` or `creation_only` entry of
   `model.Parameters` for a procedure of `procContexts`", and `@value` is one parameter
   of each `sp_change*` procedure in `17-parameters.txt`, so one encoder must serve
   all its properties). If the implementer instead keys by (procedure, property), the
   coverage test as specified passes trivially and nothing pins the per-property
   forms the campaign used.

3. R6 versus R7 on case: `TestProfileDropOnlyUnused` requires a `ProfileUses` row
   named `LAB-DISTRIB` (another case) to block a profile drop, i.e. the uses comparison
   is case-insensitive, while R7 says profiles match "by exact name" and R6 says only
   "compared on `agent_type` and name". The test and its break step define the
   case-insensitive reading, so this is a wording ambiguity rather than a defect;
   msdb profile names are case-insensitive in the server's collation anyway.

No findings left out: 3 verified, 3 hypotheses.

## Not a problem

Things I checked and found sound:

- **Cost table citations.** Every row the Task 7 table cites from the existing 2022
  files exists and says what the entry claims: `02-matrix` P01-P38, A01-A23, F01-F06
  (classes match the least-flags cell: P21 f11, P22 f01, P29/P31/P33/P35/P38 f10,
  P09 all-20012, A03-A05 f11/f01, A10-A13, A18 f10, A21-A22 f11, F01-F06; SNAP.P12
  f11=22547 → `Refused` 22547), `05-snapshot-flag` S1-S7 (S1/S7 ready ask 20607,
  S2/S5/S6 never; reinit asked at status 2, not at 1; S6.O6 wide for `sync_method`),
  `06-structural` C1-C5 (droparticle flag exactly when ready; C5 no 18752),
  `07-changes` DST/AGT/SUB/PRF/SHR (incl. `frequency_type` alone 14278,
  `msdb.dbo.sp_update_agent_profile` 21482, distribution-prefix ok), `08-pull` P1-P3
  (`@subscription_type` omitted → anonymous at the subscriber, 21084; subscriber-first
  drop order), `09-snapshot-pub` SNAP/SNAPI/TWIN rows cited, `13-transient` T02,
  `14-filter-view` F2bs/F2bu/F6/F6r/F6s/F6u, `15-snapshot-scope` A-F rows cited,
  `11-defaults` (`D.sp_addsubscription.push.@status|1`, `D.sp_addpublication.transactional`
  defaults all match `TestDefaultsSpecSample`, article defaults incl. non-dbo
  `destination_owner m_s`), `12-contexts`, `distributor-defaults`, `lab/README.md`
  O20. The `18-reverse RV.*` and `19-profiles PF.*` citations do not exist yet; Tasks
  1-3 create them before Task 7 reads them, which the plan orders correctly.
- **R9/R10 flag prediction, replayed live on `rv_q7x3kd_p`** (concurrent, `immediate_sync`,
  ready 1, rows at 2, after one snapshot run of my own): `sp_addarticle` with
  `@force_invalidate_snapshot = 1` → ready 0, new article's row 1, others stay 2, and
  a second `sp_addarticle` with no flag was accepted; `sp_changearticle schema_option`
  with both flags (string form) → operated row to 1, and the following
  `pre_creation_cmd` change with no flags was accepted, while the *other* article's
  change at row 2 needed only the reinit flag; `sp_changepublication sync_method`
  concurrent→native with both flags → all rows 1, then `sp_addarticle` and a
  `schema_option` change with no flags were accepted (the refused combination the
  plan refuses is indeed accepted by the server, so refusing it is safe). The whole
  `-defer-full-snapshot` sequence ran for real with the predicted flags (none after
  the first call): `immediate_sync` false → `sp_addarticle` → `sp_addsubscription
  @article = N'all'` → snapshot run (awaited row to 2, ready stays 0) →
  `immediate_sync` true, ready still 0, all rows 2 — matching `B.*` and R10.
  `sp_articlefilter` with both flags then `sp_articleview` with none: both accepted,
  matching `TestFilterChangeSequence`. Clears at ready 1 (`creation_script` NULL/`''`,
  `alt_snapshot_folder` NULL, `pre_snapshot_script` NULL, `snapshot_in_defaultfolder`
  false) all refuse 20607 at f00 and accept at f10, confirming the table's `snapshot`
  class for `set; clear`; `allow_push` to true and `status` to active on a
  no-subscription publication accept with no flags (the `RV.P` rows Task 1 measures).
- **R15 and the creation order.** The exact minimal `sp_addpublication` call of
  `TestCreationCallPassesOnlyNonDefaults` (`@publication`, `@retention = 100`,
  `@independent_agent = N'true'`, `@immediate_sync = N'true'`, `@status = N'active'`)
  was accepted and stored exactly the measured defaults for everything else. The
  full Task 19 creation sequence (replicationdboption in master, log reader in the
  publication database, publication, snapshot agent with `@frequency_type = 1,
  @active_start_date = 99991231`, articles, `sp_articlefilter` + `sp_articleview`,
  `sp_articlecolumn` drop + `sp_articleview @filter_clause = NULL` on the unfiltered
  article, `sp_addsubscription` + `sp_addpushsubscription_agent`) ran in the plan's
  order, all accepted, and the export of the result matches the desired shape
  (filter clause and procedure, `columns: [id, a]` on the filtered article, generated
  view absent). One `sp_changepublication_snapshot` carrying every `@frequency_*` and
  `@active_*` parameter in a single call was accepted (R22's change call).
- **The diff inputs.** The live `Sales` export loads and re-marshals through
  `model.Load`/`Marshal` with 0 nil properties, no findings, deep-equal round trip
  (checked with a small Go program run inside the module). The reader reads article
  columns in `column_id` order, the same order Task 17's `qTable` specifies, so R30's
  nil/`[]`/full-list equality has consistent inputs. Subscriber and server names are
  compared case-insensitively in the reader (`UPPER()`/`EqualFold`) and R7 keeps that
  for subscriptions. `sp_changedistributiondb` runs from `distribution`, `master` and
  `Sales` alike (ran it rolled back on the lab's distributor, value restored to 0), so
  the `procContexts` role `distributor` for the `DST.*` procedures is safe even though
  07-changes ran them in `Sales`. Dropping my database's last publication removed its
  log reader, agent rows and jobs (residue query empty), matching R10 and `T02`.
- **Shared-object inputs.** `profileUsesQuery` already reads every distribution
  database of the distributor (so R6's drop rule has the right input), and
  `Facts.ProfileUses` keeps the virtual-subscriber rows flagged. R18's refusal of
  major versions other than 16 is consistent with the spec's "the support claim holds
  once the campaign has run there" (only `17-parameters` ran on 2019/2025).
- **Order and strategies against lab rows 9-12**: add-article with and without
  `immediate_sync`, the refused-call-leaves-transaction-open trap (I reproduced
  `@@TRANCOUNT` left open by refused calls), and the filter-clause-only rule
  (`sp_addarticle` never carries `@filter_clause`) all match what I replayed.

## What I created on the lab and removed

On `repllab` only, all under the `rv_q7x3kd` prefix: databases `rv_q7x3kd_pdb`,
`rv_q7x3kd_sdb`, `rv_q7x3kd_cdb`, `rv_q7x3kd_csub`; tables `rv_q7x3kd_t1..t4`;
publications `rv_q7x3kd_p` (concurrent, immediate_sync, one push subscription, one
snapshot run of my own) and `rv_q7x3kd_cp` (the creation replay, plus the filter
procedure `rv_q7x3kd_flt1` created by `sp_articlefilter`); one throwaway publication
`rv_q7x3kd_pp` for the state-P cases. All were dropped (`sp_dropsubscription
@article = N'all'`, `sp_droppublication`, `sp_replicationdboption publish false`,
`DROP DATABASE`); the residue query over `sys.databases`, `msdb.dbo.sysjobs`,
`distribution.dbo.MSpublications/MSdistribution_agents/MSlogreader_agents/
MSsnapshot_agents/MSpublisher_databases/MSsubscriptions` returns zero `rv_q7x3kd`
rows, and no snapshot folder with that name remains under `ReplData/unc` or
`ReplAlt/unc`. The lab's own objects were only read: a second export of `Sales` at the
end is byte-identical to the one taken before I started. I never ran
`lab/start.sh`, never shut down or restarted anything, started no container of my own,
and never started an agent of `SalesPub`/`SalesRef`. No tracked file was modified
(`git status` clean; a temporary `tmp-rt/` Go program used for the round-trip check
was created inside the working copy and deleted immediately after).
