# Review of plan 2 (model and export), commit 762acf3

Reviewer: fresh Claude, neutral prompt. Lab: `repllab` (2022 CU27), plus one container of my own, `rv-c7m2xt`, run in turn on 2025 CU10 and 2019 CU32 and removed.

## Verified by running

1. Task 10's own setup makes `TestReadLabPullSubscription` fail. The setup creates `m_pp` with `@immediate_sync = N'false'` and then calls `sp_addpullsubscription` with only `@subscription_type = N'pull'`. I replayed it verbatim (renamed `rv_c7m2xt_*`). At the subscriber, `MSreplication_subscriptions` reads `subscription_type=1 independent_agent=1 immediate_sync=1`, while `syspublications.immediate_sync` is 0, because `sp_addpullsubscription` defaults `@immediate_sync` to 1. Task 10's own rule turns that mismatch into an `incomplete` finding, and the test asserts "no finding under `publications[m_pp]`", so it cannot pass. The plan's source, `08-pull`, used an `immediate_sync` publication, which is why it never hit this. There is a second effect: if the finding's path is the subscription or `pull_agent`, the "minus the paths under a finding" rule of `TestReadLabExportsEveryProperty` hides the whole pull agent subtree, so the pull half of that test checks nothing. The setup must pass `@immediate_sync = N'false'` (and `@independent_agent = N'true'`) to `sp_addpullsubscription`, which is also what plan 3 has to generate.

2. `checkSyncView` reports a mismatch for any matching view whose clause contains `= 1`. Task 8 takes the filter as "the text after the last `= 1`". I created a filter and a view with clause `a = 1` on my publication, in a rolled-back transaction. The definition is `... where HAS_PERMS_BY_NAME('[dbo].[rv_c7m2xt_pt1]', 'OBJECT', 'SELECT')= 1  and (a = 1)`. I wrote the function as the plan specifies, in a scratch module. All six cases of the plan's test pass, and the lab case returns `["view filter \")\", article clause \"a = 1\""]`. Any clause like `flag = 1`, `id = 10` or `status = 1` therefore gives a false `incomplete` finding, at every export, on a correct view. Plan 3 would then try to repair it, which costs a snapshot. The test cannot catch this, because none of its clauses contains `= 1`. Anchor instead on the `HAS_PERMS_BY_NAME(...)= 1` that follows the first ` where `. A multi-line clause (`a > 0\n  AND id <> 5`) parsed correctly.

3. The `multi_subnet_failover` rule makes the property unreadable on common distributors. The plan treats a NULL `provider_string` as false and any other value as nil with an `unreadable` finding, on the grounds that "the format the procedure writes is not measured". But the format can be read on the lab. `OBJECT_DEFINITION(OBJECT_ID('sys.sp_adddistributor'))` on 2022 CU27 sets `@provstr = sys.fn_getproviderstring(@distserver_with_port)`, whose definition returns `'Addr=tcp:' + @server` whenever the name contains a comma, then appends `MultiSubnetFailover=Yes;`. Measured on my 2025 container:
   - a distributor added as `<name>,1433` stores `addr=tcp:c99f6e710a97,1433`;
   - one added with `@encrypt_distributor_connection = N'optional', @trust_distributor_certificate = N'yes'` stores `encrypt=optional;trustservercertificate=yes;user id=distributor_admin;`.

   Every distributor reached on an explicit port, and on 2025 every one with encryption settings, would therefore export `multi_subnet_failover` as permanently unreadable. Those three 2025 parameters also have no field and no Task 12 rule, so Task 13 Step 2 stops on them rather than "1 `--- PASS`". Measured totals: 2025 CU10 has 319 (`sp_adddistributor` 9: `@encrypt_distributor_connection`, `@trust_distributor_certificate`, `@host_name_in_distributor_certificate`). 2019 CU32 has 307 and adds nothing (it lacks `sp_adddistributor @security_mode`, `@multi_subnet_failover`, every `@job_security_mode`, and `sp_addsubscription @subscriber_security_mode`, `@subscriber_login`, `@subscriber_password`). The model needs a parsed provider string (port, encryption, multi-subnet) rather than a NULL test.

4. The partition switch ruling contradicts the lab. The plan says "`allow_partition_switch` alone stores `0x20`, with `replicate_partition_switch` `0x60`". I ran rolled-back `sp_addpublication` calls (`@@TRANCOUNT` 0 after):

   | Call | `options` |
   |---|---|
   | `@allow_partition_switch = N'true'` | 96 (0x60) |
   | `@allow_partition_switch = N'true', @replicate_partition_switch = N'true'` | 96 (0x60) |
   | `@allow_partition_switch = N'true', @replicate_partition_switch = N'false'` | 32 (0x20) |
   | `@replicate_partition_switch = N'true'` alone | refused, 21678 |

   The bit values of Task 2 are right. The recorded fact is wrong, though: an omitted `replicate_partition_switch` defaults to true when `allow_partition_switch` is true. That is a context-dependent default plan 3 must have, and `11-defaults` has no row for it (it only measured `allow` false). The 5 and 6 of `sync_method` were confirmed.

5. Task 10 Step 5, the break step, cannot fail. The test keys `Subscribers` as `"REPLLAB"`, and the stored subscriber name it looks up is `syssubscriptions.srvname`, which is `REPLLAB` on the lab (queried). With the break ("key lookups with the stored name as is"), the lookup still finds the connection and the test stays green. It would fail only if the map were keyed `repllab`, or the stored name came from `MSreplication_subscriptions.publisher` or `MSsubscriber_info.subscriber`, which are both `repllab` (queried). Review Focus 1 is therefore not pinned by this test.

6. Task 11 Step 5, the break step, does not fail either. With `DistributorStatus` joined by publication only, the virtual subscriber rows mix in. On the lab, every `MSsubscriptions` row of `SalesPub`, the `-1` and `-2` rows included, is at status 2 (queried: 6 rows for publication 1, all 2). `TestReadLabFacts` asserts only that "every row has `distributor_status` 2" and no row count, so it passes with the broken join, whether it picks the first row or duplicates rows. The test needs an exact row count per subscription, or a lab state where a virtual row differs.

7. The Task 10 setup, run as written, fails. `sp_addsubscription @subscription_type = N'pull', @sync_type = N'automatic', @article = N'all'` "to `m_psub`" passes no `@subscriber` and is refused with `Msg 14043 ... @subscriber passed to stored procedure sp_MSrepl_addsubscriber cannot be NULL`. The cited `08-pull.sh` lines have `@subscriber = @srv`. `@distributor = @@SERVERNAME` passed literally as a parameter value works.

8. Task 2 Step 5, the break step, is nondeterministic. With 6 also mapped to `"database_snapshot"`, `codeTable.code` returns whichever key map iteration meets first. A round-trip loop over the broken table passed 4 runs out of 40 in a scratch module. `TestSyncMethodCodes` fails every time, so the step still shows a failure. The plan's claim that both tests fail is true only most of the time.

## Concluded by reading

1. Hypothesis: through the CLI, a pull subscription on a single-instance topology is always unreadable. Task 10 opens "every `-server` entry that is neither the publisher's nor the distributor's address" and passes only those in `Source.Subscribers`. On the lab, publisher, distributor and subscriber share `tcp:127.0.0.1,11980`, so `-server repllab=tcp:127.0.0.1,11980` is never opened, and every pull subscription comes out `pull_agent` nil and `unreadable`. The same happens in production wherever the subscriber is the distributor or publisher instance. The plan says nothing about reusing an existing connection for a subscriber (the publisher's is bound to the publication database, the reader wants `master`). `TestReadLabPullSubscription` builds `Source.Subscribers` itself, and no test runs the CLI path, so nothing catches it.

2. Hypothesis: the Task 12 rules map some parameters wrongly or not at all.
   - `@publisher` is `excluded`, "non-SQL Server publishers", for every procedure but `sp_adddistpublisher`. In `sp_addpullsubscription` and `sp_addpullsubscription_agent` it is the required publisher name (`stored-procedures/sp_addpullsubscription.sql:58-60` raises 14043 on NULL). The table would tell plan 3 to pass nothing for a required parameter, with a false reason.
   - No rule covers `sp_addpublication @logreader_job_name`, `sp_addlogreader_agent @job_name`, `sp_addpublication_snapshot @snapshot_job_name` and `sp_addpushsubscription_agent` / `sp_addpullsubscription_agent @job_name`. The first has no field. Mapping the others to `job_name` makes them `field`, "compared by plan 3", which contradicts the spec ("What is not compared": job names). These parameters name an existing job to reuse, so passing an exported name back at creation is wrong.
   - `sp_add_agent_profile @profile_type` and the 2022-only `sp_addsubscription @subscriber_security_mode`, `@subscriber_login`, `@subscriber_password` also have no rule.

   Task 12 will stop on several gaps; better to settle them in the plan.

3. Hypothesis: `ProfileUses` misses agents in other distribution databases. The plan reads "every row of `MSlogreader_agents`, `MSsnapshot_agents` and `MSdistribution_agents` at the distributor, all databases", but the only placeholder it defines is `{dist}`, the distribution database of this publisher. Profiles live in `msdb` and are shared by every distribution database of the distributor. Read from `{dist}` alone, a profile used only by a publisher on another distribution database reads as unused, and plan 3 would drop it, which spec "Shared distributor objects" forbids. The plan should iterate `msdb.dbo.MSdistributiondbs`.

4. Hypothesis: the view check gives false findings for some article types. Task 8 checks "every table article with a `sync_objid`". A `logbased_manualview` or `logbased_manualboth` article has a user-written view, not in `sp_articleview`'s format, so it reads "view definition not recognized" and gets an `incomplete` finding at every export. The existing reader also guards `syncObjID != objID`, which suggests a `sync_objid` can be the table itself. `OBJECT_DEFINITION` of a table is NULL, which the plan reads as an `unreadable` finding. Neither case was on the lab.

5. Hypothesis, low cost: the `database is offline` and `restoring` errors of `PublisherProbe.Start` cannot be reached through the CLI. `runExport` opens the publisher connected to the publication database, and that connection fails before `Probe` runs. It is still an error, never an absence, so the spec holds, but the CLI shows a connection message instead.

## Not a problem

- The parameter listing: 316 on 2022 CU27, every per-procedure count as the plan gives it.
- The Task 6 lab values match:
  - `sys.master_files`: `/var/opt/mssql//DATA/distribution.MDF` and `.LDF`;
  - `deletebatchsize_xact` 5000 and `deletebatchsize_cmd` 2000;
  - `repl_distributor`: linked login `uses_self_credential=0`, `remote_name=distributor_admin`, `provider_string` NULL;
  - `IsSyncWithBackup` 0 and `storage_connection_string` NULL;
  - `MSsubscriber_info` has a row `REPLLAB`/`repllab` of type 0, created implicitly by `sp_addsubscription` through `sp_MSrepl_addsubscriber`.
- A snapshot publication built as Task 6 describes (rolled back) stores `SQL` for all three commands.
- Task 7: on all three agent tables, `job_login` NULL, jobs enabled, `proxy_id` NULL. The snapshot commands carry `-DistributorSecurityMode 1`.
- Task 9: `lab-distrib` has description `lab profile`, `def_profile` 0 and `-CommitBatchSize` 200, and no agent is bound to it.
- Task 11: `immediate_sync_ready` is 1 on `SalesPub` and 0 on `SalesRef`. `MSsnapshot_history` has `runstatus` 2 rows, `Customer` has status 57 with the active bit, and the log reader and both distribution agent jobs are running according to `sysjobactivity` of the latest session.
- Every `MSsubscription_properties` column Task 10 names exists. The pull job's step uid equals `job_step_uid`, and the pull job has no schedule. `-SubscriberSecurityMode 1` is in its command.
- yaml.v3 v3.0.1 behaves as the plan says: `*[]T` keeps `[]`, explicit zeros load non-nil, `KnownFields` names unknown fields through inline structs, and a plain `[]string{}` does not round-trip.
- The plan's teardown order left nothing behind (publications, databases, objects, jobs, agent rows all 0).

## Objects created and removed

On `repllab`:
- Table `Sales.dbo.rv_c7m2xt_pt1`, database `rv_c7m2xt_psub`, publication `rv_c7m2xt_pp` with its snapshot agent job (never started), the pull subscription, and its pull agent job (no schedule, never ran). All were removed by the teardown; a final count found 0 publications, databases, objects, jobs, distribution and snapshot agent rows, no `unc` folder, and `@@TRANCOUNT` 0.
- `rv_c7m2xt_snap`, `rv_c7m2xt_o1` to `o8`, `rv_c7m2xt_flt` and `rv_c7m2xt_v` existed only inside transactions that were rolled back.

Container: `rv-c7m2xt` on 127.0.0.1:12417 (2025, then 2019), removed with `podman rm -f`. No lab object was modified, and no lab agent was started.
