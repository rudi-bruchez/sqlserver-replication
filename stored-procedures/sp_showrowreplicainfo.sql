SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_showrowreplicainfo]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_showrowreplicainfo] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_showrowreplicainfo]
	@ownername [sysname],
	@tablename [sysname],
	@rowguid [uniqueidentifier],
	@show [nvarchar](20)
WITH EXECUTE AS CALLER
AS
set nocount on

    -- Security check
    if (1 <> is_member('db_owner') and
        not exists (select * from dbo.sysmergearticles a join dbo.MSmerge_contents c 
                        on a.nickname=c.tablenick
                        where c.rowguid=@rowguid and
                              1 = {fn ISPALUSER(a.pubid)}))
    begin    
        RAISERROR (15247, 11, -1)
        return (1)
    end

    -- some constants
    -- this stored proc is for debugging purposes, thus no need for localizing them
    declare @dbname sysname
    select @dbname= db_name()

    declare @missingcolname sysname
    set @missingcolname= '<Missing column>'

    declare @anonymousname sysname
    set @anonymousname= '<Anonymous subscriber>'

    declare @unknownname sysname
    set @unknownname= '<Unknown server name>'

    declare @mergename sysname
    set @mergename= '<Merge nickname>'

    declare @toohighlineageversion nvarchar(128)
    set @toohighlineageversion= 'Problem found: Version is higher than the one of the first entry.'

    declare @toohighcolvversion nvarchar(128)
    set @toohighcolvversion= 'Problem found: Version is higher than highest version in lineage.'

    declare @navalue sysname
    set @navalue= '<n/a>'

    declare @unknownvalue nvarchar(9)
    set @unknownvalue= '<unknown>'

    declare @qualified_tablename nvarchar(300)

    if @tablename is NULL
    begin
        set @tablename= (select top 1 object_name(objid) from dbo.sysmergearticles where 
                            nickname = (select tablenick from dbo.MSmerge_contents where rowguid = @rowguid))
    end

    if @tablename is NULL
    begin
        set @tablename= (select top 1 object_name(objid) from dbo.sysmergearticles where 
                            nickname = (select tablenick from dbo.MSmerge_tombstone where rowguid = @rowguid))
    end

    if @tablename is null
    begin
        raiserror (20513, 16, 1, @dbname)
        return 1
    end

    -- check whether given table exists
    if not exists (select * from sys.objects where type = 'U' and name = @tablename)
    begin
        raiserror (20507, 16, 1, @tablename, @dbname)
        return 1
    end

    if @ownername is not null
    begin
        select @qualified_tablename= quotename(@ownername) + '.' + quotename(@tablename)

        -- check whether table belongs to the given owner
        if object_id(@qualified_tablename, 'U') is NULL
        begin
            raiserror (20507, 16, 1, @qualified_tablename, @dbname)
            return 1
        end
    end
    else
        select @qualified_tablename= @tablename

    -- get tableid and tablenick from tablename
    declare @tableid int
    declare @tablenick int
    set @tableid= object_id(@qualified_tablename)
    select @tablenick = (select top 1 nickname from dbo.sysmergearticles where objid = @tableid)
    if @tablenick is null
    begin
        raiserror (20027, 16, 1, @tablename)
        return 1
    end

    -- check whether there is an entry for this row in either MSmerge_contents or MSmerge_tombstone
    declare @incontents int
    declare @lineage varbinary(311)
    select @lineage= lineage from dbo.MSmerge_contents where rowguid = @rowguid
    if @lineage is not null
    begin
        set @incontents= 1
    end
    else
    begin
        select @lineage= lineage from dbo.MSmerge_tombstone where rowguid = @rowguid
        if @lineage is not null
        begin
            set @incontents= 0
        end
        else
        begin
            raiserror(21511,10,1)
            return 0
        end
    end

    -- create temporary table for information about lineage and colv entries
    create table #results (    type nchar(7) null, 
                rowversion_table nchar(17) null, 
                server_name sysname null, 
                [db_name] sysname null,  
                db_nickname binary(6) not null,
                current_state nvarchar(9) null,
                colid smallint null, 
                colname sysname null, 
                version int not null, 
                comment nvarchar(255) null,
                position smallint null) 
    
    -- insert lineage information into temptable
    insert into #results (position, db_nickname, version) exec sys.sp_showlineage @lineage=@lineage
    update #results set type= 'lineage'
    if (@incontents = 1)
    begin
        update #results set rowversion_table = 'MSmerge_contents'
    end
    else
    begin
        update #results set rowversion_table = 'MSmerge_tombstone'
    end

    if (@incontents = 1) and (lower(@show collate SQL_Latin1_General_CP1_CS_AS) in ('both', 'columns'))
    begin
        -- insert colv information into temptable
        declare @colv varbinary(2953)
        select @colv= colv1 from dbo.MSmerge_contents where rowguid=@rowguid
        if @colv is not null
        begin
            insert into #results (colid, db_nickname, version) exec sys.sp_showcolv @colv=@colv
            update #results set type= 'colv' where type is null

            -- translate colids into column names
            if (select top 1 missing_col_count from dbo.sysmergearticles where nickname = @tablenick) = 0
            begin
                -- no missing cols: position of entries in colv correspond to colid in dbo.sysmergearticles
                update #results set colname = c.name from sys.columns c where #results.colid = c.column_id and c.object_id = @tableid
            end
            else
            begin
                -- missing cols: colv has entries for columns that do not exist in this db
                declare @colname sysname
                declare @ismissing int
                declare @missingsofar int
                declare @colid int
                declare @missingcols varbinary(128)
                select @missingcols= (select top 1 missing_cols from dbo.sysmergearticles where nickname = @tablenick)
                set @missingsofar= 0
                select @colid= (select min(colid) from #results where colname is null and colid is not null)
                while @colid is not null
                begin
                    -- is this column missing?
                    exec @ismissing= sys.sp_MStestbit @missingcols, @colid
                    if @ismissing <> 0
                    begin
                        update #results set colname= @missingcolname, server_name= @navalue, [db_name]= @navalue
                                             where colid = @colid
                        set @missingsofar= @missingsofar + 1
                    end
                    else
                    begin
                        select @colname= (select name from sys.columns where object_id = @tableid and column_id = (@colid - @missingsofar))
                        update #results set colname= @colname where colid = @colid
                    end
                    
                    select @colid= (select min(colid) from #results where colname is null and colid is not null)
                end
            end
        end
    end

    -- transform null comment to empty strings
    update #results set comment= ''

    -- translate nicknames in temptable into real db names; set server names, too
    declare @subid uniqueidentifier
    declare @servername sysname
    declare @replnick binary(6)
    declare @mergenickmin binary(1)
    declare @mergenickmax binary(1)
    declare @mergenicktail binary(5)

    set @mergenickmin= 0x01
    set @mergenickmax= 0x32 -- there are not more than 50 relevant entries in a lineage
    set @mergenicktail= 0x0000000000

    update #results set [db_name]= @mergename, server_name= @navalue where 
        substring(db_nickname,1,1) >= @mergenickmin and 
        substring(db_nickname,1,1) <= @mergenickmax
        and substring(db_nickname,2,5) = @mergenicktail

    select @replnick= (select top 1 db_nickname from #results where [db_name] is null)
    while @replnick is not null
    begin
        select @subid= (select top 1 s.subid
                            from dbo.sysmergesubscriptions s where replnickname = @replnick)

        select @dbname= (select [db_name] from dbo.sysmergesubscriptions where subid = @subid)
        if @dbname is null
        begin
            set @dbname=@anonymousname
            set @servername= @unknownname
        end
        else
        begin
            select @servername = subscriber_server from dbo.sysmergesubscriptions where subid = @subid
        end

        update #results set [db_name]= @dbname, server_name= @servername 
                        where db_nickname = @replnick and [db_name] is null
        select @replnick= (select top 1 db_nickname from #results where [db_name] is null)
    end

    -- indicate which lineage entries stand for the current state of the row
    declare @firstreplnick binary(6)
    select @firstreplnick= (select db_nickname from #results where type = 'lineage' and position = 1)
    if (
            substring(@firstreplnick,1,1) < @mergenickmin or 
            substring(@firstreplnick,1,1) > @mergenickmax or
            substring(@firstreplnick,2,5) <> @mergenicktail
        )
    begin
        update #results set current_state= 'y' where type = 'lineage' and position = 1
    end
    else if @firstreplnick = 0x010000000000
    begin
        -- lineage format of SQL2000 and earlier
        update #results set current_state= @navalue where type = 'lineage' and position = 1
        update #results set current_state= 'y' where type = 'lineage' and position = 2
        update #results set current_state= @unknownvalue where type = 'lineage' and position > 2
    end
    else
    begin
        declare @cRelevantEntries int
        set @cRelevantEntries= cast(substring(@firstreplnick,1,1) as int)
        update #results set current_state= @navalue where type = 'lineage' and position = 1
        update #results set current_state= 'y' where type = 'lineage' and position > 1 and position <= @cRelevantEntries + 1
    end
    update #results set current_state= 'n' where current_state is null

    -- record lineage versions that are higher than the version in the first slot
    update #results set comment= @toohighlineageversion 
            where type = 'lineage' and
            position <> 1 and
            version > (select version from #results where position = 1)

    -- record colv versions that are higher than highest lineage version
    update #results set comment= @toohighcolvversion 
            where type = 'colv' and 
            not exists (select version from #results r where type = 'lineage' and r.version >= #results.version)
    
    -- deliver results
    if lower(@show collate SQL_Latin1_General_CP1_CS_AS) in ('both', 'row')
    begin
        select server_name, [db_name], db_nickname, version, current_state, rowversion_table, comment from #results where type = 'lineage' order by position
    end

    if lower(@show collate SQL_Latin1_General_CP1_CS_AS) in ('both', 'columns')
    begin
        select server_name, db_name, db_nickname, version, colname, comment from #results where type = 'colv' order by position
    end

    drop table #results
    return 0
GO
GRANT EXECUTE ON [sys].[sp_showrowreplicainfo] TO [public] AS [dbo]
GO
