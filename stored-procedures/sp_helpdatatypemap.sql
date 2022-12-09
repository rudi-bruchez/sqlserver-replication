SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_helpdatatypemap]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_helpdatatypemap] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_helpdatatypemap]
	@source_dbms [sysname],
	@source_version [varchar](10),
	@source_type [sysname],
	@destination_dbms [sysname],
	@destination_version [varchar](10),
	@destination_type [sysname],
	@defaults_only [bit]
WITH EXECUTE AS CALLER
AS
BEGIN
	DECLARE @retcode int
	
	--
	-- Security Check.
	--
	EXEC @retcode = sys.sp_MSreplcheck_publish
	IF @@ERROR <> 0 or @retcode <> 0
	BEGIN
		RETURN(1)
	END

	SELECT	hdm.mapping_id as [mapping_id],
			hdm.source_dbms + 
			case
				when hdm.source_version is not null then ' ' + hdm.source_version
				else ''
			end as [source_dbms],
			sys.fn_MSrepl_sourcetype
			(
				hdm.source_type,
				hdm.source_length_min,
				hdm.source_length_max,
				hdm.source_precision_min,
				hdm.source_precision_max,
				hdm.source_scale_min,
				hdm.source_scale_max,
				hdm.source_createparams
			) as [source_type],
			hdm.destination_dbms +
			case
				when hdm.destination_version is not null then ' (' + hdm.destination_version + ')'
				else ''
			end as [destination_dbms],
			sys.fn_MSrepl_sourcetype
			(
				hdm.destination_type,
				case hdm.destination_length
					when -1 then hdm.source_length_min
					else hdm.destination_length
				end,
				case hdm.destination_length
					when -1 then hdm.source_length_max
					else hdm.destination_length
				end,
				case hdm.destination_precision
					when -1 then hdm.source_precision_min
					else hdm.destination_precision
				end,
				case hdm.destination_precision
					when -1 then hdm.source_precision_max
					else hdm.destination_precision
				end,
				case hdm.destination_scale
					when -1 then hdm.source_scale_min
					else hdm.destination_scale
				end,
				case hdm.destination_scale
					when -1 then hdm.source_scale_max
					else hdm.destination_scale
				end,
				hdm.destination_createparams
			)
			as [destination_type],
			hdm.dataloss as [dataloss],
			hdm.is_default as [is_default]
	FROM	sys.fn_helpdatatypemap
			(
				@source_dbms,
				@source_version,
				@source_type,
				@destination_dbms,
				@destination_version,
				@destination_type,
				@defaults_only
			) hdm
	ORDER BY	[source_dbms],
				[source_version],
				[destination_dbms],
				[destination_version],
				[source_type],
				[is_default] desc,
				[destination_type]

	RETURN (0)
END
GO
GRANT EXECUTE ON [sys].[sp_helpdatatypemap] TO [public] AS [dbo]
GO
