# Lab

A SQL Server 2022 Developer container (CU27 on 2026-11-10) that is at once distributor, publisher and push subscriber, with SQL Agent enabled. It is the instance the measurements of `docs/analysis/step-1-analysis.md` are run on.

```
export MSSQL_SA_PASSWORD=...
lab/start.sh          # recreates the container repllab (127.0.0.1:11980) and runs setup.sql
```

`start.sh` creates the snapshot folder `/var/opt/mssql/data/ReplData` and gives it to `mssql`; `sp_adddistpublisher` refuses a working directory that does not exist (error 21037).

`setup.sql` builds:

- `SalesPub`: independent agent, `immediate_sync`, a row filter (`FLTR_Customer`), a named synchronization view (`SYNC_Customer`), a column filter, a non-default `schema_option`, custom commands and a renamed destination (`Orders` → `OrdersCopy`);
- `SalesRef`: shared distribution agent, with a schema-only view article;
- push subscriptions of both to `SalesSub` on the same instance, and a user-defined distribution profile `lab-distrib`.

Export it:

```
REPLCFG_PASSWORD=$MSSQL_SA_PASSWORD replcfg export -publisher 'tcp:127.0.0.1,11980' \
    -distributor 'tcp:127.0.0.1,11980' -database Sales -user sa -param encrypt=disable
```

`-distributor` is needed because the distributor registered at the publisher is the container hostname, which does not resolve from the host.

Stop the container when done (`SHUTDOWN` through sqlcmd, then `podman rm repllab`): each instance takes 1 to 1.5 GB.

## Measured

`measure-articles.sql`, SQL Server 2022 CU27, 2026-11-10:

| # | Measure | Result |
|---|---|---|
| 1 | `sp_addpublication` without `sp_addpublication_snapshot` | `MSsnapshot_agents` has a row with `local_job = 0` and the `job_id` of a job that does not exist |
| 2 | default `schema_option` of a table article | `0x30073` (Learn says `0x30F3`; `0x80` primary key is not set, the primary key travels as the clustered index) |
| 3 | `schema_option` with `0x8` (timestamp as timestamp) | `sysarticles.status` gets `0x8` (column names in INSERT) and `0x20`, undocumented |
| 4 | `@filter_clause` in `sp_addarticle` alone | the clause is stored, no filter procedure is created |
| 5 | `sp_articlefilter` and `sp_articleview` with names | `type` stays 1: the `manual filter` / `manual view` types are not what tells a user-named object |
| 6 | `sp_articlecolumn @operation = 'drop'` | neither `type` nor `status` change |
| 7 | `sp_articlefilter` without `@filter_name`; `upd_cmd = 'SCALL'` without a procedure | errors 14043 and 15251: a filter procedure is always named by the user, and the CALL family needs a procedure name |
| 8 | `sysschemaarticles.pre_creation_cmd` for the default `drop` | 1, the same code as `sysarticles`; Learn's "1 = Delete, 2 = Drop" for schema articles is wrong for 1 |

Also seen while building the lab: SQL Server 2022 stores the generated command procedures schema-qualified (`CALL [dbo].[sp_MSins_dboCustomer]`), and the subscriber name in `syssubscriptions` is upper case (`REPLLAB`) while `@@SERVERNAME` is `repllab`. Server names must be compared without regard to case.

Still to measure: whether an article with a filter clause and no filter procedure (row 4) is filtered at all, in the snapshot or in the log reader.
