SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSgetdynsnapvalidationtoken]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSgetdynsnapvalidationtoken] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSgetdynsnapvalidationtoken]
	@publication [sysname],
	@dynamic_filter_login [sysname]
WITH EXECUTE AS CALLER
AS
begin
    set nocount on
    declare @validation_token nvarchar(4000)
    declare @string_literalized_dynamic_filter_login nvarchar(4000)
    declare @command nvarchar(4000)
    declare @pubid uniqueidentifier
    declare @tokenfilename sysname
    declare @tokenheader nvarchar(512)
    declare @retcode int
    
    exec @retcode=sys.sp_MSrepl_PAL_rolecheck @publication = @publication
    if @retcode<>0 or @@ERROR<>0 return (1)

    select @tokenfilename = N'dynsnapvalidation.tok'    

    if @dynamic_filter_login is null or @dynamic_filter_login = N''
    begin
        select @dynamic_filter_login = suser_sname()
    end
    if @@error<>0 return 1
    select @string_literalized_dynamic_filter_login =
        sys.fn_replmakestringliteral(@dynamic_filter_login)

    select @validation_token = null
    
    if object_id('dbo.sysmergepublications') is not null
    begin 
        select @validation_token = validate_subscriber_info,
               @pubid = pubid
          from dbo.sysmergepublications
         where lower(publisher) = lower(publishingservername())
           and publisher_db = db_name()
           and name = @publication
    end         
    if @@error <> 0 return 1

    select @tokenheader =
        isnull(reverse(substring(reverse(schematext),
                                 len(@tokenfilename) + 2, 
                                 charindex(N'\', 
                                           reverse(schematext), 
                                           len(@tokenfilename) + 2) 
                                 - len(@tokenfilename) - 2)), '') + ',' +
            convert(nvarchar(36), newid()) + N','            
          from dbo.sysmergeschemachange
        where pubid = @pubid
          and schematype = 71

    -- Replaces all instances of suser_sname() with @string_literalized_dynamic_filter_login  
    -- (case-insensitive)
    select @validation_token = 
        replace(@validation_token collate SQL_Latin1_General_CP1_CI_AS,
                N'suser_sname()' collate SQL_Latin1_General_CP1_CI_AS,
                @string_literalized_dynamic_filter_login collate SQL_Latin1_General_CP1_CI_AS)
    if @@error <> 0 return 1
    
    -- Replaces all instances of system_user with @string_literalized_dynamic_filter_login
    -- (case-insensitive)
    select @validation_token =
        replace(@validation_token collate SQL_Latin1_General_CP1_CI_AS,  
                N'system_user' collate SQL_Latin1_General_CP1_CI_AS,
                @string_literalized_dynamic_filter_login collate SQL_Latin1_General_CP1_CI_AS)
    if @@error <> 0 return 1
        
    select @validation_token = rtrim(ltrim(@validation_token))
    if @validation_token = N'' select @validation_token = null        
    select @command = N'select ''dynsnapvalidationtoken'' = ' +
                sys.fn_replmakestringliteral(@tokenheader) collate database_default + 
                ' + convert(nvarchar(4000), case when rtrim(ltrim(' + isnull(@validation_token, 'N''<<Undefined dynamic snapshot validation token>>''') + ')) = N'''' then N''<<Undefined dynamic snapshot validation token>>'' else ' + isnull(@validation_token, 'N''<<Undefined dynamic snapshot validation token>>''') + ' end)' 
    if @@error <> 0 return 1
    exec (@command)
    if @@error <> 0 return 1

    return 0

end     
GO
GRANT EXECUTE ON [sys].[sp_MSgetdynsnapvalidationtoken] TO [public] AS [dbo]
GO
