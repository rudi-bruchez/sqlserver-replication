SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSaddlightweightmergearticle]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSaddlightweightmergearticle] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSaddlightweightmergearticle]
	@pubid [uniqueidentifier],
	@article_name [sysname],
	@artid [uniqueidentifier],
	@tablenick [int],
	@destination_owner [sysname],
	@identity_support [int],
	@destination_object [sysname],
	@column_tracking [bit],
	@upload_options [tinyint],
	@well_partitioned [bit],
	@status [int],
	@processing_order [int],
	@delete_tracking [bit],
	@compensate_for_errors [bit],
	@stream_blob_columns [bit]
WITH EXECUTE AS CALLER
AS
set nocount on

	declare @err				int
	declare @rcnt				int
	declare @pubname			sysname
	declare @pubidstring		nchar(32)
	declare @artidstring		nchar(32)
	declare @postfix			nchar(32)
	declare @objid				int
    declare @qualified_name 	nvarchar(270)
	declare @retcode			int
	declare @upload_options_previous tinyint
	declare @deletetracking_previous bit
	declare @compensate_for_errors_previous bit
	declare @pubidcopy			uniqueidentifier
	declare @stream_blob_columns_previous bit

    -- security check
    exec @retcode = sys.sp_MSreplcheck_subscribe
    if (@retcode <> 0 or @@error <> 0)
        return 1
        
    -- Make sure the article does not already exist in a heavyweight subscription.
	if exists (select top 1 artid from dbo.sysmergearticles 
					where nickname = @tablenick and lightweight=0)
	begin
		raiserror(21526,16,1, @article_name)
		return 1
	end

	if @destination_owner = '' or @destination_owner is null
		set @qualified_name= quotename(@destination_object)
	else
		set @qualified_name= quotename(@destination_owner) + '.' + quotename(@destination_object)

	set @objid= object_id(@qualified_name)

	-- Create the numeric part of the procedure names, and make sure it is unique.
	exec @retcode = sys.sp_MSguidtostr @artid, @artidstring out
	if @@error <> 0 or @retcode <> 0 return 1

	set @pubidcopy= @pubid

	while 1=1
	begin
		exec @retcode = sys.sp_MSguidtostr @pubidcopy, @pubidstring out
		if @@error <> 0 or @retcode <> 0 return 1
		set @postfix= substring(@artidstring, 1, 16) + substring(@pubidstring, 1, 16)

		if exists (select * from dbo.sysmergearticles where procname_postfix = @postfix)
		begin
			set @pubidcopy= newid()
		end
		else
		begin
			break
		end
	end

	-- If that article is already part of another publication, reuse its "upload_options" property.
	set @upload_options_previous = (select top 1 upload_options 
									from dbo.sysmergearticles
									where artid = @artid)
	if @upload_options_previous is not null
		set @upload_options = @upload_options_previous

	-- If that article is already part of another publication, reuse its "compensate_for_errors" property.
	set @compensate_for_errors_previous= (select top 1 compensate_for_errors 
											 from dbo.sysmergearticles
											 where artid = @artid)
	if @compensate_for_errors_previous is not null
		set @compensate_for_errors= @compensate_for_errors_previous
				
	-- If that article is already part of another publication, reuse its "delete_tracking" property.
	set @deletetracking_previous= 1
	select @deletetracking_previous= delete_tracking  from dbo.sysmergearticles
										where artid = @artid and
											  delete_tracking = 0
	if 0 = @deletetracking_previous
		set @delete_tracking= 0
		
	-- If that article is already part of another publication, reuse its "stream_blob_columns" property.
	set @stream_blob_columns_previous= 1
	select @stream_blob_columns_previous= stream_blob_columns  from dbo.sysmergearticles
										where artid = @artid and
											  stream_blob_columns = 0
	if 0 = @stream_blob_columns_previous
		set @stream_blob_columns= 0
		
	update dbo.sysmergearticles set
			name=					@article_name,
			nickname=				@tablenick,
			destination_object=		@destination_object,
			destination_owner=		@destination_owner,
			identity_support=		@identity_support,
			objid=					@objid,
			sync_objid=				@objid,
			procname_postfix=		@postfix,
			upload_options=			@upload_options,
			column_tracking=		@column_tracking,
			well_partitioned_lightweight=@well_partitioned,
			processing_order=		@processing_order,
			lightweight=			1,
			status=					@status,
			delete_tracking=		@delete_tracking,
			compensate_for_errors=	@compensate_for_errors,
			stream_blob_columns=	@stream_blob_columns
		where pubid = @pubid and artid = @artid

	select @err= @@error, @rcnt= @@rowcount
	if @err <> 0
	begin
		select @pubname = name from dbo.sysmergepublications where pubid = @pubid
		raiserror (20009, 16, -1, @article_name, @pubname)
		return 1
	end
	if @rcnt <> 0 return 0
	
	insert into dbo.sysmergearticles 
	(
		pubid, 
		name, 
		artid, 
		nickname, 
		destination_object, 
		destination_owner,
		identity_support, 
		objid, 
		sync_objid, 
		procname_postfix, 
		upload_options,
		compensate_for_errors,
		column_tracking,
		well_partitioned_lightweight,
		processing_order,
		lightweight,
		status,
		delete_tracking,
		stream_blob_columns
	)
	values 
	(
		@pubid, 
		@article_name, 
		@artid, 
		@tablenick, 
		@destination_object, 
		@destination_owner,
		@identity_support, 
		@objid, 
		@objid, 
		@postfix, 
		@upload_options,
		@compensate_for_errors,
		@column_tracking,
		@well_partitioned,
		@processing_order,
		1,
		@status,
		@delete_tracking,
		@stream_blob_columns
	)
	if @@error <> 0
	begin
		select @pubname = name from dbo.sysmergepublications where pubid = @pubid
		raiserror (20009, 16, -1, @article_name, @pubname)
		return 1
	end

	return 0
GO
GRANT EXECUTE ON [sys].[sp_MSaddlightweightmergearticle] TO [public] AS [dbo]
GO
