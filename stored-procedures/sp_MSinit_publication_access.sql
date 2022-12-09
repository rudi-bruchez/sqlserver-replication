SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSinit_publication_access]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSinit_publication_access] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSinit_publication_access]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@initinfo [nvarchar](max),
	@skip [bit]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	declare @publisher_id smallint
			,@retcode int
			,@publication_id int
			,@login sysname
			,@sid varbinary(85)
			,@itemstart bigint
			,@itemend bigint
	--
	-- sysadmin check
	--
	if (isnull(is_srvrolemember(N'sysadmin'),0) = 0)
	begin
		raiserror(21089,16,-1) 
		return (1)
	end
	--
	-- initinfo should not be null
	--
	if (@initinfo is null or @initinfo = N'')
		return 0

	exec sys.sp_MSget_server_portinfo 
		@name = @publisher, 
		@srvname = @publisher OUTPUT

	--
	-- Check if publisher is a defined as a distribution publisher in the current database
	--
	exec @retcode = sys.sp_MSvalidate_distpublisher @publisher, @publisher_id OUTPUT
	if @retcode <> 0
		return(1)
	--
	-- validate publication
	--
	select @publication_id = publication_id 
	from dbo.MSpublications 
	where 
		publisher_id = @publisher_id and
		publisher_db = @publisher_db and
		publication = @publication
	--
	-- Publication does not exist
	--
	if @publication_id is null
	begin
		raiserror (20026, 16, -1, @publication)
		return (1)
	end
	--
	-- while there are items 
	--
	select @itemstart = charindex(N'<item\>', @initinfo)
	while (@itemstart > 0)
	begin
		select @itemend = charindex(N'</item\>', @initinfo, @itemstart)
		select @login = substring(@initinfo, @itemstart + 7, @itemend - @itemstart - 7)
		--
		-- Check to see if the login exists - should have valid SID
		--
		select @sid = suser_sid(@login,0)
		if (@sid is not null)
		begin
			-- Add login to the access list if it does not exist
			if not exists (select * from dbo.MSpublication_access 
								where publication_id = @publication_id and
										sid = @sid)
			begin
				insert dbo.MSpublication_access (publication_id, login, sid)
					values (@publication_id,@login,@sid)
				if  @@error <> 0
					return(1)
			end
		end
		else
		begin
			-- Login does not have access
			if @skip = 0
			begin
				raiserror(21048, 16, 1, @login, @@servername) 
				return (1)
			end
		end
		--
		-- get the start of next item
		--
		select @itemstart = charindex(N'<item\>', @initinfo, @itemend)
	end -- while (@itemstart > 0)
	--
	-- all done
	--
	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSinit_publication_access] TO [public] AS [dbo]
GO
