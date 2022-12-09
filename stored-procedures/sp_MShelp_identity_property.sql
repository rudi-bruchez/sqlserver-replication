SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MShelp_identity_property]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MShelp_identity_property] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MShelp_identity_property]
	@tablename [sysname],
	@ownername [sysname]
WITH EXECUTE AS CALLER
AS
BEGIN
declare @qualified_name     nvarchar(270)
            ,@objid                int
            ,@retcode            int
            ,@proc                nvarchar(300)
            ,@distributor        sysname
            ,@distribdb            sysname
            ,@publisher            sysname
            ,@publisherdb        sysname
            ,@pub_range            bigint
            ,@sub_range            bigint
            ,@threshold            int
            ,@artid                int
            ,@next_seed            bigint
            ,@current_max        bigint
            ,@replicated_already    bit
            ,@auto_identity_support int
            ,@identity_incr        int 
            ,@current_identity    bigint
            ,@max_identity        bigint    
            ,@xprec                int
            ,@xtype                int
            ,@republishing        bit
            ,@length                int

select @replicated_already = 0
        ,@auto_identity_support = 0
        ,@republishing = 0
        ,@pub_range    = NULL
        ,@sub_range    = NULL
        ,@threshold    = NULL
        ,@next_seed    = NULL
        ,@current_max    = NULL

-- Security check
exec @retcode = sys.sp_MSrepl_PAL_rolecheck
if (@retcode <> 0) or (@@error <> 0)
begin
    RAISERROR (14126, 11, -1)
    return 1
end

if @ownername is not NULL
begin
    select @qualified_name = QUOTENAME(@ownername) + '.' + QUOTENAME(@tablename)
    select @objid = object_id(@qualified_name)
end
else
begin
    select @qualified_name = QUOTENAME(@tablename)
    select @objid = object_id from sys.objects where name=@tablename
end
if @objid is NULL
begin
    raiserror(14027, 16, -1, @tablename)
    return (1)
end

if OBJECTPROPERTY(@objid, 'tablehasidentity') <> 1
begin
    raiserror(21194, 16, -1)
    return (1)
end

select @xtype=system_type_id, @xprec=precision, @length=max_length from sys.columns where object_id=@objid and is_identity=1

select @max_identity = case @xtype 
                         when 52 then power((convert(bigint,2)), 8*2 -1) - 1 --smallint 
                         when 48 then power((convert(bigint,2)), 8 - 1) - 1          --tinyint
                         when 56 then power((convert(bigint,2)), 8*4 - 1) - 1          --int
                         when 127 then power((convert(bigint,2)), 62) -1 + power((convert(bigint,2)), 62)          --bigint
                         else power((convert(bigint,2)), 62) - 1 + power((convert(bigint,2)), 62)               --bigint;.
                       end

if (@xtype=108 or @xtype=106) and @xprec<18
    select @max_identity = power((convert(bigint,10)), (@xprec+1)) - 1

select @identity_incr = IDENT_INCR(@qualified_name)
        ,@current_identity =  isnull(ident_current(@qualified_name), ident_seed(@qualified_name))

if object_id('sysmergearticles') is not NULL
begin
    if exists (select * from dbo.sysmergearticles where objid=@objid)
    begin
        declare @articleid uniqueidentifier
        select @replicated_already = 1,
               @auto_identity_support = isnull(identity_support,0),
               @pub_range = pub_range,
               @sub_range = range,
               @threshold = threshold,
               @articleid = artid
        from dbo.sysmergearticles where objid=@objid and (sys.fn_MSmerge_islocalpubid(pubid)=1)
        if exists (select pubid from dbo.sysmergearticles where artid = @articleid and (sys.fn_MSmerge_islocalpubid(pubid)=0))
            select @republishing = 1
        select @next_seed = max_used from dbo.MSmerge_identity_range where artid=@articleid and is_pub_range=1 and (sys.fn_MSmerge_islocalsubid(subid)=1)            
    end
end

if object_id('sysarticles') is not NULL
begin
    if exists (select * from sysarticles where objid=@objid)
    begin
        select @replicated_already = 1,
                 @artid = artid from sysarticles where objid=@objid
        select @auto_identity_support = isnull(identity_support,0) from sysarticleupdates where artid=@artid

        if @auto_identity_support=1
        begin
            select @pub_range    = 0
                    ,@sub_range    = 0
                    ,@threshold    = 0
                    ,@next_seed    = 0
                    ,@current_max    = 0
                    ,@publisher=publishingservername()
                    ,@publisherdb=db_name()

            EXEC @retcode = sys.sp_MSrepl_getdistributorinfo     @rpcsrvname = @distributor OUTPUT,
                 @distribdb   = @distribdb   OUTPUT
            IF @@error <> 0 OR @retcode <> 0
                RETURN (1)

            IF @distribdb is null
            BEGIN
                RAISERROR (14071, 16, -1)
                RETURN (1)
            END
             
            SELECT @proc = RTRIM(@distributor) + '.' + RTRIM(@distribdb) + '.dbo.sp_MScheck_pub_identity'
            exec @retcode = @proc @publisher=@publisher, 
                                @publisher_db=@publisherdb,  
                                @tablename=@tablename,
                                @current_max=@current_max OUTPUT,
                                @pub_range=@pub_range OUTPUT,
                                @range = @sub_range OUTPUT,
                                @threshold=@threshold OUTPUT,
                                @next_seed = @next_seed OUTPUT
            if @retcode<>0 or @@ERROR<>0
                return (1)

            -- Tran pub range is not stored at the distributor
            if @pub_range = 0
            begin
                if object_id('MSpub_identity_range') is not null
                begin
                    select @pub_range = pub_range from MSpub_identity_range where objid = @objid 
                end
            end
        end
    end
end
--
-- process identityrangemanagementoption
-- NFR enabled
-- check if auto_identity_support is set - AUTO else MANUAL
--
if (@auto_identity_support != 1) and 
    exists (select name from sys.columns
                where object_id = @objid and
                is_identity = 1 and -- is identity
                ColumnProperty(object_id, name, 'IsIdNotForRepl') = 1) -- No 'not for repl' property
begin
    select @auto_identity_support = 2 --manual
end

if @replicated_already = 0
begin
    select @pub_range = case @xtype 
                             when 48 then 20 --tinyint
                             when 52 then 1000 --smallint 
                             when 56 then 10000 --int
                             when 127 then 100000 --bigint
                             else 100000 --bigint
                           end

    select @sub_range = case @xtype 
                             when 48 then 20 --tinyint
                             when 52 then 100 --smallint 
                             when 56 then 1000 --int
                             when 127 then 10000 --bigint
                             else 10000 --bigint
                           end

end

SELECT N'replicated' = @replicated_already, 
       N'auto_identity_support' = @auto_identity_support, 
       N'identity_incremental' = @identity_incr, 
       N'current_identity' = @current_identity,
       N'next_starting_seed' = @next_seed, 
       N'max_identity' = @max_identity, 
       N'publisher_range' = ABS(@pub_range), 
       N'subscriber_range' = ABS(@sub_range), 
       N'threshold' = @threshold,
       N'in_republishing' = @republishing
END
GO
GRANT EXECUTE ON [sys].[sp_MShelp_identity_property] TO [public] AS [dbo]
GO
