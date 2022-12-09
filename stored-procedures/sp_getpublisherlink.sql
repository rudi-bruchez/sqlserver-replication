SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_getpublisherlink]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_getpublisherlink] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_getpublisherlink]
	@trigger_id [int],
	@connect_string [nvarchar](300) OUTPUT,
	@islocalpublisher [bit] OUTPUT
WITH EXECUTE AS CALLER
AS
BEGIN
    SET NOCOUNT ON
    declare @publisher sysname
                ,@publisher_db sysname
                ,@linkname sysname
                ,@security_mode int
                ,@retcode int

    --
    -- Make sure this proc is called from the trigger.
    -- Better to use object_id if owner name is passed in.
    --
    if trigger_nestlevel(@trigger_id) = 0
    begin
        raiserror(14126, 16, -1)
        return (1) -- current user does not have insert permission to underlying table
    end
    --
    -- Get the security information
    --
    IF object_id('MSsubscription_properties', 'U') is not NULL
    begin
        --
        -- MSsubscription_properties exists
        -- Check for the subscription
        --
        select @linkname = case when (p.publisher_security_mode in (0,1)) 
                            then sys.fn_MSrepllinkname(N'REPLLINK', upper(o.publisher), o.publisher_db, o.publication, db_name())
                            else p.publisherlink end
                ,@security_mode = case when (p.publisher_security_mode not between 0 and 2) then null else cast(p.publisher_security_mode as tinyint) end
                ,@publisher = upper(o.publisher)
                ,@publisher_db = o.publisher_db
        from MSsubscription_properties p join MSreplication_objects o
            on UPPER(p.publisher) = UPPER(o.publisher) 
                and p.publisher_db = o.publisher_db
                and p.publication = o.publication
                and o.object_name = object_name(@trigger_id) 
        select @islocalpublisher = case when (@publisher = upper(publishingservername())) then 1 else 0 end
        if (@security_mode is null)
        begin
            --
            -- entry for the subscription does not exist
            -- or, sp_link_publication has not been called
            --
            raiserror(21079, 16, 1)
            return(1)
        end
    end
    else
    begin
        --
        -- MSsubscription_properties does not exist
        --
        raiserror(21079, 16, 3)
        return(1)
    end
    --
    -- if we have come this far - the subscription exists
    --
    select @connect_string = case when (@islocalpublisher = 1) 
                    then quotename(@publisher_db)
                    else quotename(@linkname) + N'.' + quotename(@publisher_db)
                    end
    --
    -- all done
    --
    return 0
END
GO
GRANT EXECUTE ON [sys].[sp_getpublisherlink] TO [public] AS [dbo]
GO
