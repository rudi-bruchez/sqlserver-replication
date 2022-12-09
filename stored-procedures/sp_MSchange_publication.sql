SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSchange_publication]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSchange_publication] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSchange_publication]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@property [sysname],
	@value [nvarchar](255)
WITH EXECUTE AS CALLER
AS
BEGIN
	set nocount on
	
 	declare @publisher_id smallint
 			,@publication_type int
 			,@retcode int
 			,@max_distretention int
 			,@retention_value int
 			,@cmd    nvarchar(4000)
 			,@cmd2   nvarchar(4000)
 			,@cmd3   nvarchar(4000)
 			,@retention_period_unit tinyint

 	declare @setvalue int
	--
	-- security check
	-- only db_owner can execute this
	--
	if (is_member ('db_owner') != 1) 
	begin
		raiserror(14260, 16, -1)
		return (1)
	end
	--
	-- security check
	-- Has to be executed from distribution database
	--
	if (sys.fn_MSrepl_isdistdb (db_name()) != 1)
	begin
		raiserror(21482, 16, -1, 'sp_MSchange_publication', 'distribution')
		return (1)
	end
	-- Check if publisher is a defined as a distribution publisher in the current database
	exec @retcode = sys.sp_MSvalidate_distpublisher @publisher, @publisher_id OUTPUT
	if @retcode <> 0
	begin
		return(1)
	end

	/* Charater properties  */

	begin tran
	save tran sp_MSchange_publication

	IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) ='description'
	BEGIN
		UPDATE dbo.MSpublications SET description = @value
			WHERE   publisher_id = @publisher_id AND
					publisher_db = @publisher_db AND
					publication = @publication
		IF @@ERROR <> 0 
			goto UNDO
	END
	ELSE if LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) IN ('retention')
	BEGIN
		select @retention_value = convert(int, @value)
		select @publication_type = publication_type
			from dbo.MSpublications
			WHERE   publisher_id = @publisher_id AND
					publisher_db = @publisher_db AND
					publication = @publication
		UPDATE dbo.MSpublications set retention=@retention_value 
		WHERE   publisher_id = @publisher_id AND
					publisher_db = @publisher_db AND
					publication = @publication
		if @@ERROR<>0
				goto UNDO
	END
	ELSE if LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) IN ('retention_period_unit')
	BEGIN
		select @retention_period_unit = convert(tinyint, @value)
		UPDATE dbo.MSpublications set retention_period_unit=@retention_period_unit 
		WHERE   publisher_id = @publisher_id AND
					publisher_db = @publisher_db AND
					publication = @publication
		if @@ERROR<>0
				goto UNDO
	END
	ELSE if LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = ('queue_type')
	BEGIN
		--
		-- Value could be 1 or 2
		--
		if (convert(int, @value) = 1)
		begin
			--
			-- Changing to MSMQ (for pre Yukon publishers)
			-- Distributor needs to support MSMQ 2.0 - Just check that
			-- Now we use xp_MSver to detect NT OS version
			-- MSMQ subscription only allowed for platforms that support MSMQ 2.0
			-- version 5.0.2195 or higher
			--
			create table #tosversion ( propid int, propname sysname collate database_default, value int, charvalue nvarchar(255) collate database_default)
			insert into #tosversion (propid, propname, value, charvalue)
				exec master.dbo.xp_msver N'WindowsVersion'

			declare @vervalue int
						,@lobyte tinyint
						,@hibyte tinyint
						,@loword smallint
						,@hiword smallint

			--
			-- low order byte of low order word = OSmajor, high order byte of low order word = OSminor
			-- high order word = OSbuild
			--
			select @vervalue = value from #tosversion where propname = N'WindowsVersion'
			select @loword = (@vervalue & 0xffff)
					,@hiword = (@vervalue / 0x10000) & 0xffff
			select @lobyte = @loword & 0xff
					,@hibyte = (@loword / 100) & 0xff
			drop table #tosversion
			--
			-- check for OS major version
			--
			if (@lobyte < 5)
			begin
				raiserror(21334, 16, 6, '2.0')
				goto UNDO
			end
			--
			-- check for OS build version
			--
			if (@lobyte = 5 and @hiword < 2195)
			begin
				raiserror(21334, 16, 7, '2.0')
				goto UNDO
			end
		end
		else if (convert(int, @value) = 2)
		begin
			--
			-- Changing to SQL (for upgrade)
			-- cleanup the MSMQ created for this subscriptions that are active
			-- and switch to SQL for distribution agents
			--
			exec @retcode = sp_MSrefreshmqtosql @publisher ,@publisher_db, @publication
			IF @@ERROR <> 0 
				goto UNDO
		end
	END
	ELSE IF LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = N'options'
	BEGIN
		UPDATE dbo.MSpublications 
				SET options = CONVERT(int, @value)
			WHERE publisher_id = @publisher_id 
				AND publisher_db = @publisher_db 
				AND publication = @publication
		IF @@ERROR <> 0
			GOTO UNDO
	END
	ELSE if LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) = ('min_autonosync_lsn')
	BEGIN
		UPDATE dbo.MSpublications
		set min_autonosync_lsn = case when @value is null then NULL else CONVERT(varbinary(16), @value) end
			WHERE publisher_id = @publisher_id
				AND publisher_db = @publisher_db
				AND publication = @publication
		if @@error <> 0 
			GOTO UNDO
	END
	ELSE
	BEGIN
		SELECT @cmd = N''
		SELECT @cmd = @cmd + N'UPDATE dbo.MSpublications '
		SELECT @cmd = @cmd + N'   SET ' + LOWER(@property collate SQL_Latin1_General_CP1_CS_AS) + N' = '
		/* @value can be 255 nchars, so don't append it */
		SELECT @cmd2 = N' WHERE publisher_id = ' + STR(@publisher_id)
		SELECT @cmd2 =  @cmd2 + N' AND publisher_db = N' + quotename(@publisher_db, N'''')
		SELECT @cmd2 =  @cmd2 + N' AND publication = N'  + quotename(@publication, N'''')
		EXECUTE (@cmd + @value + @cmd2)
		IF @@ERROR <> 0 
			goto UNDO
	END

	COMMIT TRAN
	RETURN(0)

UNDO:
	IF (@@TRANCOUNT > 0)
	begin
		ROLLBACK TRAN sp_MSchange_publication
		COMMIT TRAN   
	end
	RETURN (1)
END
GO
GRANT EXECUTE ON [sys].[sp_MSchange_publication] TO [public] AS [dbo]
GO
