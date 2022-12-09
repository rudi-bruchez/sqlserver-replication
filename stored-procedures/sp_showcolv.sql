SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_showcolv]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_showcolv] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_showcolv]
	@colv [varbinary](2953)
WITH EXECUTE AS CALLER
AS
set nocount on

    declare @result table (colidx smallint, replnick binary(6), version int)

    declare @i smallint
    set @i= 0
    while (@i < DATALENGTH(@colv)/12)
    begin
        declare @colidx smallint
        set @colidx= cast(substring(@colv, @i*12+2,1) as smallint)
        set @colidx= @colidx*256 + cast(substring(@colv, @i*12+1,1) as smallint)

        declare @replnick binary(6)
        set @replnick= (select substring(@colv, @i*12+3, 6))

        declare @version int
        set @version= cast(substring(@colv, @i*12+12,1) as int)
        set @version= @version*256 + cast(substring(@colv, @i*12+11,1) as int)
        set @version= @version*256 + cast(substring(@colv, @i*12+10,1) as int)
        set @version= @version*256 + cast(substring(@colv, @i*12+9,1) as int)
        
        insert into @result(colidx, replnick, version) select @colidx+1, @replnick, @version
        set @i= @i+1
    end
    select * from @result order by colidx
GO
GRANT EXECUTE ON [sys].[sp_showcolv] TO [public] AS [dbo]
GO
