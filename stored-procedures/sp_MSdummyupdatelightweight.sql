SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdummyupdatelightweight]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdummyupdatelightweight] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdummyupdatelightweight]
	@tablenick [int],
	@rowguid [uniqueidentifier],
	@action [int],
	@metatype [tinyint],
	@rowvector [varbinary](11)
WITH EXECUTE AS CALLER
AS
declare @METADATA_TYPE_Missing tinyint
	declare @METADATA_TYPE_Tombstone tinyint
	declare @METADATA_TYPE_Contents tinyint
	declare @METADATA_TYPE_ContentsDeferred tinyint
	declare @METADATA_TYPE_InsertLightweight tinyint
	declare @METADATA_TYPE_UpdateLightweight tinyint
	declare @METADATA_TYPE_UpsertLightweightProcessed tinyint
	declare @METADATA_TYPE_DeleteLightweight tinyint
	declare @METADATA_TYPE_DeleteLightweightProcessed tinyint

	declare @METADATA_ACTION_Default int
	declare @METADATA_ACTION_RequestEnumAllColumns int

	declare @COLUMNS_ENUMERATED_ChangedOnly tinyint
	declare @COLUMNS_ENUMERATED_AllOnConflictOrError tinyint
	declare @COLUMNS_ENUMERATED_AllOnOtherReason tinyint

	declare @retcode 		int
	declare @pubnick 		tinyint
	declare @coltracked		bit
	declare @enumtype_delete tinyint

	-- do permission checking
	exec @retcode = sys.sp_MSreplcheck_subscribe
	if @retcode<>0 or @@ERROR<>0 return (1)

	set @METADATA_TYPE_Missing= 0
	set @METADATA_TYPE_Tombstone= 1
	set @METADATA_TYPE_Contents= 2
	set @METADATA_TYPE_ContentsDeferred= 3
	set @METADATA_TYPE_InsertLightweight= 7 
	set @METADATA_TYPE_UpdateLightweight= 8
	set @METADATA_TYPE_DeleteLightweight= 10
	set @METADATA_TYPE_UpsertLightweightProcessed= 11
	set @METADATA_TYPE_DeleteLightweightProcessed= 12

	set @METADATA_ACTION_Default= 0
	set @METADATA_ACTION_RequestEnumAllColumns= 1

	set @COLUMNS_ENUMERATED_ChangedOnly= 0
	set @COLUMNS_ENUMERATED_AllOnConflictOrError= 1
	set @COLUMNS_ENUMERATED_AllOnOtherReason= 2

	select top 1 @coltracked= column_tracking from dbo.sysmergearticles
								where nickname=@tablenick

	if 1=@coltracked
	begin
		set @enumtype_delete= @COLUMNS_ENUMERATED_ChangedOnly
	end
	else
	begin
		set @enumtype_delete= @COLUMNS_ENUMERATED_AllOnOtherReason
	end

	if (@action=@METADATA_ACTION_RequestEnumAllColumns)
	begin
		-- The previous upload of that row was not applied to the publisher, either because
		-- of an error, or because we had a conflict, but only sent changed columns.
		-- As a consequence, want to resend the entire row at the next merge.
		update dbo.MSmerge_rowtrack
			set changetype= @METADATA_TYPE_UpdateLightweight,
				columns_enumeration= @COLUMNS_ENUMERATED_AllOnConflictOrError,
				changed= sys.fn_MSdayasnumber(getdate())
			where tablenick = @tablenick and
				  rowguid = @rowguid and
				  changetype in (@METADATA_TYPE_InsertLightweight,
				  				 @METADATA_TYPE_UpdateLightweight, 
				  				 @METADATA_TYPE_UpsertLightweightProcessed)
	end
	else if (@metatype = @METADATA_TYPE_Missing)
	begin
		-- We do not have the row. Put in a tombstone to cause a delete at the other side.
		insert into dbo.MSmerge_rowtrack 
		(
			tablenick,
			rowguid,
			changetype,
			rowvector,
			changedcolumns,
			columns_enumeration,
			changed
		)
		values
		(
			@tablenick,
			@rowguid,
			@METADATA_TYPE_DeleteLightweight,
			@rowvector,
			null,
			@enumtype_delete,
			sys.fn_MSdayasnumber(getdate())
		)
	end
	else if (@metatype in (@METADATA_TYPE_Tombstone,
						   @METADATA_TYPE_DeleteLightweight,
						   @METADATA_TYPE_DeleteLightweightProcessed))
	begin
		update dbo.MSmerge_rowtrack
		set changetype= @METADATA_TYPE_DeleteLightweight, 
		rowvector= case 
			when @rowvector is null then rowvector
			else @rowvector
		end,
		changedcolumns= null,
		columns_enumeration= @enumtype_delete,
		changed= sys.fn_MSdayasnumber(getdate())
		where tablenick = @tablenick and rowguid = @rowguid
	end
	else if (@metatype in (@METADATA_TYPE_Contents,
						   @METADATA_TYPE_InsertLightweight,
						   @METADATA_TYPE_UpdateLightweight,
						   @METADATA_TYPE_UpsertLightweightProcessed))
	begin
		update dbo.MSmerge_rowtrack
			set changetype= @METADATA_TYPE_UpdateLightweight,
				rowvector= case 
					when @rowvector is null then rowvector
					else @rowvector
				end,
				changedcolumns= null,
				columns_enumeration= @COLUMNS_ENUMERATED_AllOnOtherReason,
				changed= sys.fn_MSdayasnumber(getdate())
			where tablenick = @tablenick and rowguid = @rowguid
	end
	else if (@metatype = @METADATA_TYPE_ContentsDeferred)
	begin
		insert into dbo.MSmerge_rowtrack 
		(
			tablenick,
			rowguid,
			changetype,
			rowvector,
			changedcolumns,
			columns_enumeration,
			changed
		)
		values
		(
			@tablenick,
			@rowguid,
			@METADATA_TYPE_UpdateLightweight,
			@rowvector, 
			null,
			@COLUMNS_ENUMERATED_AllOnOtherReason,
			sys.fn_MSdayasnumber(getdate())
		)
	end

	return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSdummyupdatelightweight] TO [public] AS [dbo]
GO
