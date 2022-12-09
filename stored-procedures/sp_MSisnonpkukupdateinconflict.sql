SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSisnonpkukupdateinconflict]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSisnonpkukupdateinconflict] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSisnonpkukupdateinconflict]
	@pubid [int],
	@artid [int],
	@bitmap [varbinary](4000)
WITH EXECUTE AS CALLER
AS
begin
	declare @retcode int
		,@tabname sysname
		,@tabid int
		,@indid int
		,@indkey int
		,@key sysname
		,@colid int
		,@isset int
		,@artcol int
		,@bytepos int
		,@bitpos int
	declare @ukcoltab table(ukindex int identity, keyname sysname collate database_default not null)

	--
	-- security check
	--
	exec @retcode = sp_MSreplcheck_publish
	if @@ERROR != 0 or @retcode != 0
		return -1
	--
	-- initalize and validate
	--
	select @tabid = objid
		,@artcol = 0
	from dbo.sysarticles
	where (artid = @artid) and (pubid = @pubid)
	--
	-- validate article
	--
	if (@tabid is null)
	begin
		raiserror(21344, 16, -1, '@pubid, @artid')
		return -1
	end
	--
	-- the table should have non PK unique keys
	--
	exec @retcode = sp_repltablehasnonpkuniquekey @tabid
	if (@retcode != 1)
	begin
		return 0
	end
	--
	-- get fully qualified table
	--
	select @tabname = QUOTENAME(schema_name(OBJECTPROPERTY(@tabid, 'SchemaId'))) collate database_default 
			+ N'.' + QUOTENAME(object_name( @tabid )) collate database_default

	--
	-- get the non PK unique indices
	--
	declare #hcindid cursor local fast_forward for
		select indid from sysindexes 
		where id = @tabid 
			and (status & 2) != 0
			and (status & 2048) = 0
			and indid > 0 and indid < 255
		order by indid asc
	open #hcindid
	fetch #hcindid into @indid
	while (@@fetch_status != -1)
	begin
		--
		-- create an enumeration of all the columns 
		-- that are part of selected unique index
		--
		select @indkey = 1
		while (@indkey <= 16)
		begin
			select @key = index_col( @tabname, @indid, @indkey )
			if (@key is null)
				break
			else
			begin
				if not exists (select * from @ukcoltab where keyname = @key)
					insert into @ukcoltab(keyname) values(@key)
			end
			select @indkey = @indkey + 1
		end
		--
		-- fetch next index
		--
		fetch #hcindid into @indid
	end
	close #hcindid
	deallocate #hcindid
	--
	-- now walk through each article col and if it is
	-- a part of any of the unique keys, then check if the update bitmap bit 
	-- corresponding to any article column is set
	--
	declare #hccolid cursor local fast_forward for
		select column_id, [name] from sys.columns 
		where object_id = @tabid order by column_id asc

	open #hccolid
	fetch #hccolid INTO @colid, @key
	while (@@fetch_status != -1)
	begin
		exec @isset = sp_isarticlecolbitset @colid, @artid
		if (@isset != 0)
		begin
			--
			-- this column is part of the article
			--
			select @artcol = @artcol + 1
			if exists (select * from @ukcoltab where keyname = @key)
			begin
				--
				-- this column is part of an unique key
				--
				select @bytepos = 1 + (@artcol-1) / 8 
					,@bitpos = power(2, (@artcol-1) % 8 )
				--
				-- if the update bitmap has bit set then
				-- then it is a nonPK key update
				--
				if ((substring(@bitmap, @bytepos, 1) & @bitpos) = @bitpos)
					return 1
			end
		end		
		--
		-- get the next column
		--
		fetch #hccolid INTO @colid, @key
	end
	close #hccolid
	deallocate #hccolid
	--
	-- if we have reached here then it mean the update does not
	-- affect PK columns, cleanup and return
	--
	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_MSisnonpkukupdateinconflict] TO [public] AS [dbo]
GO
