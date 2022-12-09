SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSsub_set_identity]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSsub_set_identity] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSsub_set_identity]
	@objid [int],
	@threshold [int],
	@range [bigint],
	@next_seed [bigint]
WITH EXECUTE AS CALLER
AS
declare @retcode int

    --  Security Check
    EXEC @retcode = sys.sp_MSreplcheck_subscribe
    IF @@ERROR <> 0 or @retcode <> 0
    RETURN(1)

    -- Stored last_seed in @next_seed
    select @next_seed = @next_seed - @range

    update MSsub_identity_range set 
        last_seed = @next_seed,
        threshold = @threshold,
        range = @range
        where objid = @objid
    IF @@ERROR <> 0
        return 1
    -- RESEED and change constraint
    exec @retcode = sys.sp_MSreseed
        @objid = @objid,
        @next_seed = @next_seed,
        @range = @range,
        @is_publisher = -1
    IF @@ERROR <> 0 OR @retcode <> 0
        return 1
GO
GRANT EXECUTE ON [sys].[sp_MSsub_set_identity] TO [public] AS [dbo]
GO
