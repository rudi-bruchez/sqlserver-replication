SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_showlineage]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_showlineage] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_showlineage]
	@lineage [varbinary](311)
WITH EXECUTE AS CALLER
AS
set nocount on

    declare @result table (position smallint, replnick binary(6), version int)

    declare @i smallint
    set @i= 0
    while (@i < DATALENGTH(@lineage)/10)
    begin
        declare @replnick binary(6)
        set @replnick= (select substring(@lineage, @i*10+1, 6))

        declare @version int
        set @version= cast(substring(@lineage, @i*10+10,1) as int)
        set @version= @version*256 + cast(substring(@lineage, @i*10+9,1) as int)
        set @version= @version*256 + cast(substring(@lineage, @i*10+8,1) as int)
        set @version= @version*256 + cast(substring(@lineage, @i*10+7,1) as int)
        
        insert into @result(position, replnick, version) select @i+1, @replnick, @version
        set @i= @i+1
    end
    select * from @result order by position
GO
GRANT EXECUTE ON [sys].[sp_showlineage] TO [public] AS [dbo]
GO
