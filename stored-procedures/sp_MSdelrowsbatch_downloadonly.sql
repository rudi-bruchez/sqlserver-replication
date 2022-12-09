SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSdelrowsbatch_downloadonly]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSdelrowsbatch_downloadonly] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSdelrowsbatch_downloadonly]
	@pubid [uniqueidentifier],
	@tablenick [int],
	@check_permission [int],
	@rows_tobe_deleted [int],
	@rowguid1 [uniqueidentifier],
	@rowguid2 [uniqueidentifier],
	@rowguid3 [uniqueidentifier],
	@rowguid4 [uniqueidentifier],
	@rowguid5 [uniqueidentifier],
	@rowguid6 [uniqueidentifier],
	@rowguid7 [uniqueidentifier],
	@rowguid8 [uniqueidentifier],
	@rowguid9 [uniqueidentifier],
	@rowguid10 [uniqueidentifier],
	@rowguid11 [uniqueidentifier],
	@rowguid12 [uniqueidentifier],
	@rowguid13 [uniqueidentifier],
	@rowguid14 [uniqueidentifier],
	@rowguid15 [uniqueidentifier],
	@rowguid16 [uniqueidentifier],
	@rowguid17 [uniqueidentifier],
	@rowguid18 [uniqueidentifier],
	@rowguid19 [uniqueidentifier],
	@rowguid20 [uniqueidentifier],
	@rowguid21 [uniqueidentifier],
	@rowguid22 [uniqueidentifier],
	@rowguid23 [uniqueidentifier],
	@rowguid24 [uniqueidentifier],
	@rowguid25 [uniqueidentifier],
	@rowguid26 [uniqueidentifier],
	@rowguid27 [uniqueidentifier],
	@rowguid28 [uniqueidentifier],
	@rowguid29 [uniqueidentifier],
	@rowguid30 [uniqueidentifier],
	@rowguid31 [uniqueidentifier],
	@rowguid32 [uniqueidentifier],
	@rowguid33 [uniqueidentifier],
	@rowguid34 [uniqueidentifier],
	@rowguid35 [uniqueidentifier],
	@rowguid36 [uniqueidentifier],
	@rowguid37 [uniqueidentifier],
	@rowguid38 [uniqueidentifier],
	@rowguid39 [uniqueidentifier],
	@rowguid40 [uniqueidentifier],
	@rowguid41 [uniqueidentifier],
	@rowguid42 [uniqueidentifier],
	@rowguid43 [uniqueidentifier],
	@rowguid44 [uniqueidentifier],
	@rowguid45 [uniqueidentifier],
	@rowguid46 [uniqueidentifier],
	@rowguid47 [uniqueidentifier],
	@rowguid48 [uniqueidentifier],
	@rowguid49 [uniqueidentifier],
	@rowguid50 [uniqueidentifier],
	@rowguid51 [uniqueidentifier],
	@rowguid52 [uniqueidentifier],
	@rowguid53 [uniqueidentifier],
	@rowguid54 [uniqueidentifier],
	@rowguid55 [uniqueidentifier],
	@rowguid56 [uniqueidentifier],
	@rowguid57 [uniqueidentifier],
	@rowguid58 [uniqueidentifier],
	@rowguid59 [uniqueidentifier],
	@rowguid60 [uniqueidentifier],
	@rowguid61 [uniqueidentifier],
	@rowguid62 [uniqueidentifier],
	@rowguid63 [uniqueidentifier],
	@rowguid64 [uniqueidentifier],
	@rowguid65 [uniqueidentifier],
	@rowguid66 [uniqueidentifier],
	@rowguid67 [uniqueidentifier],
	@rowguid68 [uniqueidentifier],
	@rowguid69 [uniqueidentifier],
	@rowguid70 [uniqueidentifier],
	@rowguid71 [uniqueidentifier],
	@rowguid72 [uniqueidentifier],
	@rowguid73 [uniqueidentifier],
	@rowguid74 [uniqueidentifier],
	@rowguid75 [uniqueidentifier],
	@rowguid76 [uniqueidentifier],
	@rowguid77 [uniqueidentifier],
	@rowguid78 [uniqueidentifier],
	@rowguid79 [uniqueidentifier],
	@rowguid80 [uniqueidentifier],
	@rowguid81 [uniqueidentifier],
	@rowguid82 [uniqueidentifier],
	@rowguid83 [uniqueidentifier],
	@rowguid84 [uniqueidentifier],
	@rowguid85 [uniqueidentifier],
	@rowguid86 [uniqueidentifier],
	@rowguid87 [uniqueidentifier],
	@rowguid88 [uniqueidentifier],
	@rowguid89 [uniqueidentifier],
	@rowguid90 [uniqueidentifier],
	@rowguid91 [uniqueidentifier],
	@rowguid92 [uniqueidentifier],
	@rowguid93 [uniqueidentifier],
	@rowguid94 [uniqueidentifier],
	@rowguid95 [uniqueidentifier],
	@rowguid96 [uniqueidentifier],
	@rowguid97 [uniqueidentifier],
	@rowguid98 [uniqueidentifier],
	@rowguid99 [uniqueidentifier],
	@rowguid100 [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
set nocount on
    declare @procname       nvarchar(270)
    declare @retcode int

    -- NOTE: this stored procedure returns 0 to indicate failure

    -- security check
    exec @retcode=sys.sp_MSreplcheck_subscribe
    if @retcode<>0 or @@ERROR<>0 return (1)

    if @check_permission =1
    begin
        declare @objid int
        declare @permissions int
        
        select @objid=objid, @permissions=check_permissions from dbo.sysmergearticles 
            where nickname=@tablenick and (pubid is NULL or pubid=@pubid)
        if @objid is NULL
            return (0)

        exec @retcode = sys.sp_MSreplcheck_permission @objid = @objid, @type = 3, @permissions = @permissions
        if @retcode<>0 or @@ERROR<>0 
            return (4)
    end
    
    select @procname= 'dbo.' + delete_proc from dbo.sysmergearticles where nickname = @tablenick and pubid=@pubid

    select @retcode = 1
    exec @retcode = @procname
                        @rows_tobe_deleted,
                        null,
                        @rowguid1,
                        @rowguid2,
                        @rowguid3,
                        @rowguid4,
                        @rowguid5,
                        @rowguid6,
                        @rowguid7,
                        @rowguid8,
                        @rowguid9,
                        @rowguid10,
                        @rowguid11,
                        @rowguid12,
                        @rowguid13,
                        @rowguid14,
                        @rowguid15,
                        @rowguid16,
                        @rowguid17,
                        @rowguid18,
                        @rowguid19,
                        @rowguid20,
                        @rowguid21,
                        @rowguid22,
                        @rowguid23,
                        @rowguid24,
                        @rowguid25,
                        @rowguid26,
                        @rowguid27,
                        @rowguid28,
                        @rowguid29,
                        @rowguid30,
                        @rowguid31,
                        @rowguid32,
                        @rowguid33,
                        @rowguid34,
                        @rowguid35,
                        @rowguid36,
                        @rowguid37,
                        @rowguid38,
                        @rowguid39,
                        @rowguid40,
                        @rowguid41,
                        @rowguid42,
                        @rowguid43,
                        @rowguid44,
                        @rowguid45,
                        @rowguid46,
                        @rowguid47,
                        @rowguid48,
                        @rowguid49,
                        @rowguid50,
                        @rowguid51,
                        @rowguid52,
                        @rowguid53,
                        @rowguid54,
                        @rowguid55,
                        @rowguid56,
                        @rowguid57,
                        @rowguid58,
                        @rowguid59,
                        @rowguid60,
                        @rowguid61,
                        @rowguid62,
                        @rowguid63,
                        @rowguid64,
                        @rowguid65,
                        @rowguid66,
                        @rowguid67,
                        @rowguid68,
                        @rowguid69,
                        @rowguid70,
                        @rowguid71,
                        @rowguid72,
                        @rowguid73,
                        @rowguid74,
                        @rowguid75,
                        @rowguid76,
                        @rowguid77,
                        @rowguid78,
                        @rowguid79,
                        @rowguid80,
                        @rowguid81,
                        @rowguid82,
                        @rowguid83,
                        @rowguid84,
                        @rowguid85,
                        @rowguid86,
                        @rowguid87,
                        @rowguid88,
                        @rowguid89,
                        @rowguid90,
                        @rowguid91,
                        @rowguid92,
                        @rowguid93,
                        @rowguid94,
                        @rowguid95,
                        @rowguid96,
                        @rowguid97,
                        @rowguid98,
                        @rowguid99,
                        @rowguid100
    
    if @@error<>0 and @retcode=1
        return 0

    return @retcode
GO
GRANT EXECUTE ON [sys].[sp_MSdelrowsbatch_downloadonly] TO [public] AS [dbo]
GO
