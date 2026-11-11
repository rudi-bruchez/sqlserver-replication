-- Parameter listing of the 18 replication procedures that create configuration
-- (lab/README.md, "Procedure parameters"). Read-only: it creates nothing and
-- touches no lab object. One R| row per parameter, ordered by procedure then
-- parameter_id, so that plan 2 can map every parameter to the YAML model.
-- Run through lab/campaign.sh.
SET NOCOUNT ON;
DECLARE @r TABLE (id nvarchar(200), result nvarchar(200), detail nvarchar(200), seq int IDENTITY(1,1));

INSERT @r (id, result, detail)
SELECT o.name + N'.' + p.name,
       TYPE_NAME(p.user_type_id) + N'(' + CONVERT(nvarchar(10), p.max_length) + N')',
       N'output=' + CONVERT(nvarchar(1), p.is_output) + N' id=' + CONVERT(nvarchar(10), p.parameter_id)
FROM sys.all_objects AS o
JOIN sys.all_parameters AS p ON p.object_id = o.object_id
WHERE o.schema_id = SCHEMA_ID(N'sys')
  AND o.name IN (N'sp_adddistributor', N'sp_adddistributiondb', N'sp_adddistpublisher',
                 N'sp_replicationdboption', N'sp_addlogreader_agent', N'sp_addpublication',
                 N'sp_addpublication_snapshot', N'sp_addarticle', N'sp_articlefilter',
                 N'sp_articleview', N'sp_articlecolumn', N'sp_addsubscription',
                 N'sp_addpushsubscription_agent', N'sp_addpullsubscription',
                 N'sp_addpullsubscription_agent', N'sp_add_agent_profile',
                 N'sp_add_agent_parameter', N'sp_update_agent_profile')
ORDER BY o.name, p.parameter_id;

SELECT CAST(N'R|' + id + N'|' + result + N'|' + detail AS nvarchar(4000)) FROM @r
UNION ALL SELECT N'R|TOTAL|' + CONVERT(nvarchar(10), COUNT(*)) FROM @r;
GO
