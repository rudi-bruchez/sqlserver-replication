SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSsub_check_identity]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSsub_check_identity] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSsub_check_identity]
	@lower_bound_id [int]
WITH EXECUTE AS CALLER
AS
declare @retcode int
    declare @cmd nvarchar(1000)
    declare @objid int, @threshhold bigint, @range bigint, @next_seed bigint
    declare    @last_seed bigint, @identity_so_far bigint, @threshold int
    declare @table_name sysname
    declare @qualname nvarchar(517)

    --  Security Check
    EXEC @retcode = sys.sp_MSreplcheck_subscribe
    IF @@ERROR <> 0 or @retcode <> 0
    RETURN(1)

    -- This proc will be called by distribution agent called repeatedly until
    -- one result returned
    if object_id('MSsub_identity_range') is not NULL
    begin
        while 1 = 1
        begin
            select @objid = null
            select top 1 @objid = objid from MSsub_identity_range where
                objid > @lower_bound_id 
                order by objid ASC
            if @objid is null
                break

            select @lower_bound_id = @objid
            -- Since we don't always clean up the subscriber, Skipping invalid entry.
            if object_name(@objid) is null 
                continue
            if objectproperty(@objid, 'TableHasIdentity') <> 1
                continue

            exec sys.sp_MSget_qualified_name @objid, @qualname OUTPUT

            select @range = range, @last_seed = last_seed, @threshold = threshold from 
                MSsub_identity_range where objid=@objid
                
            if @range = 0
                -- First time after initial bcp, always request a new range
                -- return this object
                break
            else
            begin                 

                -- Leave one slot unused. This is to prevent violation of primary key constraint
                -- if the next value is used by a subscriber and the publisher has received it.
                -- It seems the pk constraint will be validated before this check.
                declare @actual_range int
                if @range > 0
                    select @actual_range = @range - 1
                else
                    select @actual_range = @range + 1

                select @identity_so_far = isnull(ident_current(@qualname), ident_seed(@qualname))

                if 100*(@identity_so_far - @last_seed)/@actual_range >= @threshold
                    -- Need new range
                    break
            end

            select @lower_bound_id = @objid
        end
    end
    select @table_name = object_name(@objid)            

    -- Return nothing if @table_name is null, which means no more table needs to be adjust
    select 'objid' = @objid, 'table_name' = @table_name where @objid is not null    
GO
GRANT EXECUTE ON [sys].[sp_MSsub_check_identity] TO [public] AS [dbo]
GO
