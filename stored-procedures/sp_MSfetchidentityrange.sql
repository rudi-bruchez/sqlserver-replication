SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSfetchidentityrange]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSfetchidentityrange] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSfetchidentityrange]
	@tablename [nvarchar](270),
	@adjust_only [bit],
	@table_owner [sysname]
WITH EXECUTE AS CALLER
AS
declare @retcode            int
declare @objid              int
declare @artid uniqueidentifier
declare @pubid uniqueidentifier
declare @next_seed          bigint
declare @range              bigint
declare @identity_support   int
declare @tablenick                      int
declare @quoted_tablename   nvarchar(270)
declare @is_republisher     bit
declare @ident_current bigint
declare @ident_increment bigint
declare @range_begin numeric(38,0)
declare @range_end numeric(38,0)
declare @next_range_begin numeric(38,0)
declare @next_range_end numeric(38,0)
declare @max_used numeric(38,0)
declare @threshold int

if @table_owner is not NULL
    select @quoted_tablename = QUOTENAME(@table_owner) + '.' + QUOTENAME(@tablename)
else
    select @quoted_tablename = quotename(@tablename)

select @objid = object_id(@quoted_tablename)

select @identity_support=identity_support, @tablenick = nickname, @artid=artid, @range=range, @threshold=threshold 
    from dbo.sysmergearticles where objid=@objid

if @identity_support is NULL or @identity_support=0
begin
    -- table is not enabled for auto identity range management
    raiserror(21197, 16, -1)
    return (1)
end

/*
** do permission checking
*/
exec @retcode = sys.sp_MSrepl_PAL_rolecheck @tablenick=@tablenick
if @retcode<>0 or @@ERROR<>0 return (1)

-- check if this is a republisher.
if exists (select pubid from dbo.sysmergearticles where artid=@artid and sys.fn_MSmerge_islocalpubid(pubid)=0)
    select @is_republisher=1
else
    select @is_republisher=0

select @pubid=subid from dbo.MSmerge_identity_range where artid=@artid and is_pub_range=1 and (sys.fn_MSmerge_islocalsubid(subid)=1)
if @pubid is NULL
begin
    raiserror(20663, 16, -1)
    return (1)
end


-- get new identity. Now we do not know who the subscriber is. So it we cannot keep track
-- of this subscriber. However we will allocate a new range and update the publisher's entry
-- which indicates how much has been allocated.
-- we will allocate a new identity irrespective of what @adjust_only has been set to. This is
-- because the merge agent always calls mostly with @adjust_only being set to true and in the
-- one case that it is set to false it should really be true.
begin tran
save tran fetchidentityrange

select @ident_current = ISNULL(IDENT_CURRENT(@quoted_tablename), IDENT_SEED(@quoted_tablename))
select @ident_increment = IDENT_INCR(@quoted_tablename)

select @range_begin = range_begin,
       @range_end = range_end,
       @next_range_begin = next_range_begin,
       @next_range_end = next_range_end,
       @next_seed = max_used
    from dbo.MSmerge_identity_range with (updlock, rowlock) where artid=@artid and subid=@pubid and is_pub_range=1 
if @range_begin is NULL or @range_end is NULL or @next_seed is NULL
begin
    raiserror(21197, 16, -1)
    goto FAILURE
end

-- add one or subscract one from max_used for backward compatibility. This means between ranges we will always skip 
-- one number. That is fine if not Daytona will have overlapping ranges. Though SQL downlevel subscribers will be fine
-- Daytona will have overlapping ranges and hence this increment.
select @next_seed = @next_seed + @ident_increment

-- the following is fine even in case of negative increments since the @range value is negative
if @is_republisher=0
begin
    update dbo.MSmerge_identity_range set max_used = @next_seed+@range where artid=@artid and subid=@pubid and is_pub_range=1
    if @@error<>0
    begin
        raiserror(21197, 16, -1)
        goto FAILURE
    end
end
else
begin
    if @ident_increment>0
    begin
        if @range_end >= @next_seed and @range_begin <= @next_seed
        begin
            if (@next_seed+@range) <= @range_end
            begin
                -- there is enough space in the first range
                update dbo.MSmerge_identity_range set max_used = @next_seed+@range where artid=@artid and subid=@pubid and is_pub_range=1
                if @@error<>0
                begin
                    raiserror(21197, 16, -1)
                    goto FAILURE
                end
            end
            else
            begin
                -- we need to start using the second range
                select @next_seed = @next_range_begin
                if @next_range_begin is NULL
                begin
                    raiserror(21197, 16, -1)
                    goto FAILURE
                end
                update dbo.MSmerge_identity_range set max_used = @next_seed+@range where artid=@artid and subid=@pubid and is_pub_range=1
                if @@error<>0
                begin
                    raiserror(21197, 16, -1)
                    goto FAILURE
                end
            end
        end
        else if @next_range_end >= @next_seed and @next_range_begin <= @next_seed
        begin
            if (@next_seed+@range) <= @next_range_end
            begin
                -- there is enough space in the second range
                update dbo.MSmerge_identity_range set max_used = @next_seed+@range where artid=@artid and subid=@pubid and is_pub_range=1
                if @@error<>0
                begin
                    raiserror(21197, 16, -1)
                    goto FAILURE
                end
            end
            else
            begin
                -- there is not enough range at the republisher to allocate for it subscriber
                raiserror(20665, 16, -1)
                goto FAILURE
            end
        end
        else
        begin
            -- there is something terribly wrong here. @max_used is not in the ranges available at the publisher
            raiserror(21197, 16, -1)
            goto FAILURE
        end
    end
    else
    begin
        if @range_end <= @next_seed and @range_begin >= @next_seed
        begin
            if (@next_seed+@range) >= @range_end
            begin
                -- there is enough space in the first range
                update dbo.MSmerge_identity_range set max_used = @next_seed+@range where artid=@artid and subid=@pubid and is_pub_range=1
                if @@error<>0
                begin
                    raiserror(21197, 16, -1)
                    goto FAILURE
                end
            end
            else
            begin
                -- we need to start using the second range
                select @next_seed = @next_range_begin
                if @next_range_begin is NULL
                begin
                    raiserror(21197, 16, -1)
                    goto FAILURE
                end
                update dbo.MSmerge_identity_range set max_used = @next_seed+@range where artid=@artid and subid=@pubid and is_pub_range=1
                if @@error<>0
                begin
                    raiserror(21197, 16, -1)
                    goto FAILURE
                end
            end
        end
        else if @next_range_end <= @next_seed and @next_range_begin >= @next_seed
        begin
            if (@next_seed+@range) >= @next_range_end
            begin
                -- there is enough space in the second range
                update dbo.MSmerge_identity_range set max_used = @next_seed+@range where artid=@artid and subid=@pubid and is_pub_range=1
                if @@error<>0
                begin
                    raiserror(21197, 16, -1)
                    goto FAILURE
                end
            end
            else
            begin
                -- there is not enough range at the republisher to allocate for it subscriber
                raiserror(20665, 16, -1)
                goto FAILURE
            end
        end
        else
        begin
            -- there is something terribly wrong here. @max_used is not in the ranges available at the publisher
            raiserror(21197, 16, -1)
            goto FAILURE
        end
    end
end
commit tran

select @range_begin = @next_seed, @range_end = @next_seed+@range

if @is_republisher=0
begin
    declare @publication sysname
    select @publication = name from dbo.sysmergepublications where pubid = @pubid

    -- set the values about the current allocation on the distributor.
    exec @retcode = sys.sp_MSmerge_log_idrange_alloc_on_distributor    
                    NULL,
                    @artid, 
                    0, -- is_pub_range 0 because we just allocated to a subscriber
                    1, -- we allocated only one range since this a backward compat thing
                    @range_begin,
                    @range_end,
                    NULL, -- next_range_begin is NULL because we are allocating only one range to a downlevel subscriber
                    NULL, -- next_range_end is NULL because we are allocating only one range to a downlevel subscriber
                    @publication,
                    N'',
                    N''
end


--initialize article collection for agents.
select @identity_support, @next_seed, @range, @threshold

return 0
FAILURE:
    if @@trancount>0
    begin
        rollback tran fetchidentityrange
        commit tran
    end
    return 1
GO
GRANT EXECUTE ON [sys].[sp_MSfetchidentityrange] TO [public] AS [dbo]
GO
