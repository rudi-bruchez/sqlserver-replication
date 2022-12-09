SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSproxiedmetadatalightweight]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSproxiedmetadatalightweight] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSproxiedmetadatalightweight]
	@tablenick [int],
	@rowguid [uniqueidentifier],
	@pubid [uniqueidentifier],
	@acknowledge_only [bit],
	@rowvector [varbinary](11)
WITH EXECUTE AS CALLER
AS
set nocount on
	
	declare @METADATA_TYPE_InsertLightweight tinyint
	declare @METADATA_TYPE_UpdateLightweight tinyint
	declare @METADATA_TYPE_DeleteLightweight tinyint
	declare @METADATA_TYPE_UpsertLightweightProcessed tinyint
	declare @METADATA_TYPE_DeleteLightweightProcessed tinyint
	declare @pubnick	tinyint
	declare @error		int
	declare @rowcount	int
	declare @retcode	smallint
	declare @removefrompartialvector binary(1)
	declare @versionzerovector binary(11)
	declare @coltracked	bit
	declare @COLUMNS_ENUMERATED_ChangedOnly tinyint
	declare @COLUMNS_ENUMERATED_AllOnOtherReason tinyint

	set @METADATA_TYPE_InsertLightweight= 7 
	set @METADATA_TYPE_UpdateLightweight= 8
	set @METADATA_TYPE_DeleteLightweight= 10
	set @METADATA_TYPE_UpsertLightweightProcessed= 11
	set @METADATA_TYPE_DeleteLightweightProcessed= 12
	set @removefrompartialvector= 0x00
	set @versionzerovector= 0x00000000000000000000FF
	set @COLUMNS_ENUMERATED_ChangedOnly= 0
	set @COLUMNS_ENUMERATED_AllOnOtherReason= 2

	-- Security check
	exec @retcode= sys.sp_MSreplcheck_subscribe
	if @@error <> 0 or @retcode <> 0 return (1)

	select @pubnick= sync_info from dbo.MSmerge_replinfo where repid = @pubid

	select top 1 @coltracked= column_tracking from dbo.sysmergearticles where nickname=@tablenick

	-- We replace proxied metadata if either:
	-- 1) The sync_cookie matches. This means that there was no local change since the upload
	--	  began, and the "right" publisher is acknowledging the upload. In that case, the
	--	  change type is reset, too, because the current row value was succesfully uploaded.
	--	  The rowvector is only replaced if the currently stored version is not higher. This
	--	  could be the case because of scenario 2 described below.
	--	  In this code path, we also acknowledge uploads.
	--
	-- 2) The sync_cookie does not match, but the proxied rowvector has a higher version than
	--	  the subscriber rowvector. A non-matching cookie means that an older upload is about
	--	  to be acknowledged. It is still okay to accept that proxied rowvector, because this
	--	  proxied rowvector, due to its higher version, is already more up to date than the one
	--	  we currently store. However, we must not reset the change flag in that case,
	--	  because the acknowledge of the most recent upload is  still pending, and it might
	--	  contain a newer change.

	-- Scenario 1, where currently stored version is not already higher than the one passed in;
	-- or we simply acknowledge an upload.
	update dbo.MSmerge_rowtrack
		set rowvector= case @acknowledge_only
								when 1 then rowvector -- For a simple acknowledge, leave the vector alone.
								else @rowvector
					   end,
			changedcolumns= null,
			columns_enumeration= case @coltracked
									when 1 then @COLUMNS_ENUMERATED_ChangedOnly
									else @COLUMNS_ENUMERATED_AllOnOtherReason
								 end,
			sync_cookie= null,
			changetype= case changetype
							when @METADATA_TYPE_InsertLightweight then @METADATA_TYPE_UpsertLightweightProcessed
							when @METADATA_TYPE_UpdateLightweight then @METADATA_TYPE_UpsertLightweightProcessed
							when @METADATA_TYPE_DeleteLightweight then @METADATA_TYPE_DeleteLightweightProcessed
							else changetype
						end,
    		changed= sys.fn_MSdayasnumber(getdate())	
		where
			tablenick = @tablenick and
			rowguid = @rowguid and
			sync_cookie = @pubnick and
			(
				1=@acknowledge_only or
				(
					{fn GETMAXVERSION(
							case
								when rowvector is null then @versionzerovector
								when rowvector = @removefrompartialvector then @versionzerovector
								else rowvector
							end)}
					<= {fn GETMAXVERSION(isnull(@rowvector, @versionzerovector))}
				)
			)

	select @error= @error, @rowcount= @@rowcount

	if @error<>0
	begin
		return 1
	end
	else if 1=@rowcount
	begin
		-- No need to check for further scenarios if we just replaced the metadata.
		return 0
	end
	else
	begin
		-- Scenario 2, where currently stored version is already higher than the one passed in.
		update dbo.MSmerge_rowtrack
			set sync_cookie= null,
				changedcolumns= null,
				columns_enumeration= case @coltracked
										when 1 then @COLUMNS_ENUMERATED_ChangedOnly
										else @COLUMNS_ENUMERATED_AllOnOtherReason
									 end,
				changetype= case changetype
								when @METADATA_TYPE_InsertLightweight then @METADATA_TYPE_UpsertLightweightProcessed
								when @METADATA_TYPE_UpdateLightweight then @METADATA_TYPE_UpsertLightweightProcessed
								when @METADATA_TYPE_DeleteLightweight then @METADATA_TYPE_DeleteLightweightProcessed
								else changetype
							end,
				changed= sys.fn_MSdayasnumber(getdate())
			where
				tablenick = @tablenick and
				rowguid = @rowguid and
				sync_cookie = @pubnick

		select @error= @error, @rowcount= @@rowcount

		if @error<>0
		begin
			return 1
		end
		else if 1=@rowcount
		begin
			-- No need to check for further scenarios if we just replaced the metadata.
			return 0
		end
		else
		begin
			-- Case 2
			update dbo.MSmerge_rowtrack
				set rowvector= @rowvector,
				    changed= sys.fn_MSdayasnumber(getdate())
				where
					tablenick = @tablenick and
					rowguid = @rowguid and
					(
						{fn GETMAXVERSION(
								case
									when rowvector is null then @versionzerovector
									when rowvector = @removefrompartialvector then @versionzerovector
									else rowvector
								end)}
						<= {fn GETMAXVERSION(isnull(@rowvector, @versionzerovector))}
					)

			if @@error<>0 return 1
		end
	end

	return 0
GO
GRANT EXECUTE ON [sys].[sp_MSproxiedmetadatalightweight] TO [public] AS [dbo]
GO
