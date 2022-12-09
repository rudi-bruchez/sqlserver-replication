SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSfixlineageversions]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSfixlineageversions] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSfixlineageversions]
WITH EXECUTE AS CALLER
AS
declare @lNick int -- length of nickname in bytes
	declare @lVer int -- length of version in bytes
	declare @lEntry int -- length of entry in bytes
	declare @cEntries int -- max number of entries in a lineage
	declare @idx int -- @idx into lineage (0-based)
	declare @maxlinsize int -- maximal lineage size in bytes
	declare @retcode int
	
	set @lNick= col_length('sysmergesubscriptions', 'replnickname')
	set @lVer= 4
	set @lEntry= @lNick + @lVer
	set @cEntries= 24

	-- Security check
	exec @retcode= sys.sp_MSrepl_PAL_rolecheck
	if @retcode <> 0 or @@error <> 0
	begin    
		RAISERROR (15247, 11, -1)
		return (1)
	end

	if object_id('MSmerge_contents', 'U') is not NULL
	begin
		-- iterate over lineage: starting at the tail, replace first version by the current one if first version is less
		set @idx= @cEntries - 1
		while @idx > 0
		begin
			update dbo.MSmerge_contents set lineage= 
				-- keep nickname of first entry
				substring(lineage, 1, @lNick) +
				-- use version of current entry if it is higher than first version (this is made sure in the where-clause)
				substring(lineage, @idx * @lEntry + @lNick + 1, @lVer) +
				-- keep 2..last entry 
				substring(lineage, 1 + @lEntry, datalength(lineage) - @lEntry)

				where
					-- skip this step right away for shorter lineages
					datalength(lineage) >= @lEntry * (@idx + 1)
					and
					(
						-- the following makes sure that the version we currently look at is higher than the first one
						--
						-- either least significant version byte at current entry is higher than at first entry, the other three are equal
						(substring(lineage, @idx * @lEntry + @lNick + 1, 1) > substring(lineage, @lNick + 1, 1) and
							substring(lineage, @idx * @lEntry + @lNick + 2, 3) = substring(lineage, @lNick + 2, 3))
						or
						-- 2nd least significant version byte at current entry is higher than at first entry, the most and 2nd most significant bytes are equal
						(substring(lineage, @idx * @lEntry + @lNick + 2, 1) > substring(lineage, @lNick + 2, 1) and
							substring(lineage, @idx * @lEntry + @lNick + 3, 2) = substring(lineage, @lNick + 3, 2))
						or
						-- 3rd least significant version byte at current entry is higher than at first entry, the most significant byte is equal
						(substring(lineage, @idx * @lEntry + @lNick + 3, 1) > substring(lineage, @lNick + 3, 1) and
							substring(lineage, @idx * @lEntry + @lNick + 4, 1) = substring(lineage, @lNick + 4, 1))
						or
						-- most significant byte at current entry is higher than at first entry
						substring(lineage, @idx * @lEntry + @lNick + 4, 1) > substring(lineage, @lNick + 4, 1)
					)

			if @@error<>0
			begin
				return (1)
			end

			set @idx= @idx - 1
		end
	end
	if object_id('MSmerge_tombstone', 'U') is not NULL
	begin
		-- iterate over lineage: starting at the tail, replace first version by the current one if first version is less
		set @idx= @cEntries - 1
		while @idx > 0
		begin
				update dbo.MSmerge_tombstone set lineage= 
				-- keep nickname of first entry
				substring(lineage, 1, @lNick) +
				-- use version of current entry if it is higher than first version (this is made sure in the where-clause)
				substring(lineage, @idx * @lEntry + @lNick + 1, @lVer) +
				-- keep 2..last entry 
				substring(lineage, 1 + @lEntry, datalength(lineage) - @lEntry)

				where
					-- skip this step right away for shorter lineages
					datalength(lineage) >= @lEntry * (@idx + 1)
					and
					(
						-- the following makes sure that the version we currently look at is higher than the first one
						--
						-- either least significant version byte at current entry is higher than at first entry, the other three are equal
						(substring(lineage, @idx * @lEntry + @lNick + 1, 1) > substring(lineage, @lNick + 1, 1) and
							substring(lineage, @idx * @lEntry + @lNick + 2, 3) = substring(lineage, @lNick + 2, 3))
						or
						-- 2nd least significant version byte at current entry is higher than at first entry, the most and 2nd most significant bytes are equal
						(substring(lineage, @idx * @lEntry + @lNick + 2, 1) > substring(lineage, @lNick + 2, 1) and
							substring(lineage, @idx * @lEntry + @lNick + 3, 2) = substring(lineage, @lNick + 3, 2))
						or
						-- 3rd least significant version byte at current entry is higher than at first entry, the most significant byte is equal
						(substring(lineage, @idx * @lEntry + @lNick + 3, 1) > substring(lineage, @lNick + 3, 1) and
							substring(lineage, @idx * @lEntry + @lNick + 4, 1) = substring(lineage, @lNick + 4, 1))
						or
						-- most significant byte at current entry is higher than at first entry
						substring(lineage, @idx * @lEntry + @lNick + 4, 1) > substring(lineage, @lNick + 4, 1)
					)

			if @@error<>0
			begin
				return (1)
			end

			set @idx= @idx - 1
		end
	end
	return (0)
GO
GRANT EXECUTE ON [sys].[sp_MSfixlineageversions] TO [public] AS [dbo]
GO
