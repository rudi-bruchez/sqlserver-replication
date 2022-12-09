SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSaddpeerlsn]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSaddpeerlsn] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSaddpeerlsn]
	@originator [sysname],
	@originator_db [sysname],
	@originator_publication [sysname],
	@originator_publication_id [int],
	@originator_db_version [int],
	@originator_lsn [varbinary](10),
	@originator_version [int],
	@originator_id [int]
WITH EXECUTE AS CALLER
AS
begin
	declare @retcode bit

	-- security check for subscriber
	exec @retcode = sys.sp_MSreplcheck_subscribe 
    if @@error <> 0 or  @retcode <> 0 
    begin
        return 1
    end

	begin transaction tran_sp_MSaddpeerlsn
	save transaction tran_sp_MSaddpeerlsn

	-- if the LSN entry already exists then we will just perform a NO-OP
	if exists (select * 
					from MSpeer_lsns with (holdlock, updlock)
					where originator				= UPPER(@originator)
						and originator_db 				= @originator_db
						and originator_publication		= @originator_publication
						and originator_publication_id 	= @originator_publication_id
						and originator_db_version		= @originator_db_version)
	begin
		commit transaction tran_sp_MSaddpeerlsn
		return 0
	end
	
	if @originator_id = 0 
		select @originator_id = NULL
	
	insert into MSpeer_lsns
	(
		originator,
		originator_db,
		originator_publication,
		originator_publication_id,
		originator_db_version,
		originator_lsn,
		originator_version,
		originator_id
	)
	values
	(
		UPPER(@originator),
		@originator_db,
		@originator_publication,
		@originator_publication_id,
		@originator_db_version,
		@originator_lsn,
		@originator_version,
		@originator_id
	)
	if @@error <> 0
	begin
		-- The procedure sys.sp_MSaddpeerlsn failed to INSERT into the resource MSpeer_lsns. Server error =  @@error.
		raiserror (21499, 16, -1, 'sys.sp_MSaddpeerlsn', 'INSERT into', 'MSpeer_lsns.', @@error)
		goto FAILURE
       end


     if object_id(N'dbo.MSpeer_originatorid_history', N'U') is not NULL
     begin
        if @originator_id is not NULL and not exists(select * from dbo.MSpeer_originatorid_history where originator_publication = @originator_publication
     													     and originator_id = @originator_id
                                                                                                and UPPER(originator_node) = UPPER(@originator)
                                                                                                and originator_db = @originator_db
	                                  					                          and originator_db_version = @originator_db_version)

       begin
        insert dbo.MSpeer_originatorid_history
	        (originator_publication, originator_id, originator_node, originator_db, originator_db_version, originator_version)
	 values(@originator_publication, @originator_id, UPPER(@originator), @originator_db, @originator_db_version, @originator_version)

	 if @@error <> 0
	 begin
		-- The procedure sys.sp_MSaddpeerlsn failed to INSERT into the resource MSpeer_originatorid_history. Server error =  @@error.
		raiserror (21499, 16, -1, 'sys.sp_MSaddpeerlsn', 'INSERT into', 'MSpeer_originatorid_history.', @@error)
		goto FAILURE
          end
        end
      end

	commit transaction tran_sp_MSaddpeerlsn
	
	return 0

FAILURE:
	
	rollback transaction tran_sp_MSaddpeerlsn
	commit transaction tran_sp_MSaddpeerlsn
	
	return 1
end
GO
GRANT EXECUTE ON [sys].[sp_MSaddpeerlsn] TO [public] AS [dbo]
GO
