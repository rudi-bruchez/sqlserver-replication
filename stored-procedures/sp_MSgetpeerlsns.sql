SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgetpeerlsns]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgetpeerlsns] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgetpeerlsns]
	@publication [sysname],
	@xlockrows [bit]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on

	declare @retcode 	int,
			@dbversion	int
	
	-- security check for subscriber
	exec @retcode = sys.sp_MSreplcheck_subscribe 
    if @@error <> 0 or  @retcode <> 0 
    begin
        return 1
    end

	-- retrieve the current subscriber database version
	exec @retcode = sys.sp_MSgetdbversion @current_version = @dbversion output 
	if @retcode <> 0 or @@error <> 0
	begin
		return 1
	end
	
	-- user wants to place an exclusive lock on the retrieved rows for 
	-- the duration of the transaction in which this SP is called...
	if @xlockrows = 1 
	begin
		-- note that here we order by pk to ensure lock order
		select distinct	UPPER(originator),
				originator_db,
				originator_publication_id,
				originator_db_version,
				originator_lsn,
				id
			from MSpeer_lsns with (XLOCK, ROWLOCK, INDEX(nci_MSpeer_lsns))
			where originator_publication = @publication
					-- and they can not be local water marks or they must be from a differnt db version
					and (originator 			!= UPPER(publishingservername())
						or originator_db 			!= db_name()
						or originator_db_version 	!= @dbversion)
			order by id
		if @@error <> 0
			return 1
	end
	else
	begin
		-- same query as above without the xlock, rowlock hint and no order by
		select distinct	UPPER(originator),
				originator_db,
				originator_publication_id,
				originator_db_version,
				originator_lsn
			from MSpeer_lsns with (INDEX(nci_MSpeer_lsns))
			where originator_publication = @publication
					-- and they can not be local water marks or they must be from a differnt db version
					and (originator 			!= UPPER(publishingservername())
						or originator_db 			!= db_name()
						or originator_db_version 	!= @dbversion)
		if @@error <> 0
			return 1
	end

	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSgetpeerlsns] TO [public] AS [dbo]
GO
