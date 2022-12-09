SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgetlightweightmetadatabatch]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgetlightweightmetadatabatch] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgetlightweightmetadatabatch]
	@pubid [uniqueidentifier],
	@artnickarray [varbinary](2000),
	@rowguidarray [varbinary](8000)
WITH EXECUTE AS CALLER
AS
set nocount on
	
	declare @pubnick			int
    declare @artnick 			int
    declare @artnicklast		int
    declare @rowguid 			uniqueidentifier
    declare @type  				tinyint
    declare @retcode        	smallint
    declare @artnickarraylength int
    declare @artnickarrayidx	int
    declare @rowguidarrayidx	int
	declare @procname			nvarchar(70)
	declare @postfix			nchar(32)
	declare @rowvector			varbinary(11)
	declare @changedcolumns		varbinary(128)
	declare @artid				uniqueidentifier
	declare @columns_enumeration tinyint

	declare @METADATA_TYPE_InsertLightweight tinyint
	declare @METADATA_TYPE_UpdateLightweight tinyint
	declare @METADATA_TYPE_DeleteLightweight tinyint
	declare @METADATA_TYPE_UpsertLightweightProcessed tinyint
	declare @METADATA_TYPE_DeleteLightweightProcessed tinyint

	-- Security check
	exec @retcode= sys.sp_MSreplcheck_subscribe
	if @@error <> 0 or @retcode <> 0 return (1)

    if (@artnickarray is null)
    begin
        raiserror(14043, 16, -1, '@artnickarray', 'sp_MSgetlightweightmetadatabatch')
        return (1)
    end
    if (@rowguidarray is null)
    begin
        raiserror(14043, 16, -1, '@rowguidarray', 'sp_MSgetlightweightmetadatabatch')
        return (1)
    end
    
	set @METADATA_TYPE_InsertLightweight= 7 
	set @METADATA_TYPE_UpdateLightweight= 8
	set @METADATA_TYPE_DeleteLightweight= 10
	set @METADATA_TYPE_UpsertLightweightProcessed= 11
	set @METADATA_TYPE_DeleteLightweightProcessed= 12
    set @artnicklast= 0
    set @artnickarrayidx= 1
    set @rowguidarrayidx= 1
    set @artnickarraylength= datalength(@artnickarray)

	select @pubnick = sync_info from dbo.MSmerge_replinfo where repid = @pubid

    -- walk through arrays and populate temp table
    while (@artnickarrayidx < @artnickarraylength)
    begin
		set @artnick= substring(@artnickarray, @artnickarrayidx, 4)
		set @rowguid= substring(@rowguidarray, @rowguidarrayidx, 16)

		-- find the stored proc that figures out the metadata type of the row
		if @artnick <> @artnicklast
		begin
			select @artid= artid, @postfix= procname_postfix
				from dbo.sysmergearticles 
				where pubid = @pubid and nickname = @artnick

			select @procname= quotename('MSmerge_lws_sp_multi_' + @postfix)
			set @artnicklast= @artnick
		end

		exec @retcode= @procname
							@action= 3,
							@rowguid= @rowguid,
							@type= @type output,
							@rowvector= @rowvector output,
							@changedcolumns= @changedcolumns output,
							@columns_enumeration= @columns_enumeration output
		if @@error <>0 or @retcode <> 0 goto Failure

		select @type as type, 
		       @rowvector as rowvector, 
		       @changedcolumns as changedcolumns,
		       @columns_enumeration as columns_enumeration

		-- bump up offsets for next time through loop
		set @artnickarrayidx = @artnickarrayidx + 4
		set @rowguidarrayidx = @rowguidarrayidx + 16
	end

	return 0
Failure:
	return 1

GO
GRANT EXECUTE ON [sys].[sp_MSgetlightweightmetadatabatch] TO [public] AS [dbo]
GO
