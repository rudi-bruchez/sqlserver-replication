SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_MSevaluate_change_membership_for_row]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_MSevaluate_change_membership_for_row] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_MSevaluate_change_membership_for_row]
	@tablenick [int],
	@rowguid [uniqueidentifier],
	@marker [uniqueidentifier]
WITH EXECUTE AS CALLER
AS
begin
    declare @membership_eval_proc_name nvarchar(130), @retcode int
    
    exec @retcode = sys.sp_MSrepl_PAL_rolecheck @tablenick=@tablenick
    if @retcode<>0 or @@ERROR<>0
        return 1

    -- get the ArticleChangeMembershipEvaluation proc for this article in all publications.
    declare membership_eval_proc_names CURSOR LOCAL FAST_FORWARD FOR select membership_eval_proc_name
    from dbo.sysmergepartitioninfoview
    where nickname = @tablenick and membership_eval_proc_name is not null and membership_eval_proc_name <> ' '
    FOR READ ONLY
    
    open membership_eval_proc_names

    fetch next from membership_eval_proc_names into @membership_eval_proc_name

    while (@@fetch_status <> -1)
    begin
        select @membership_eval_proc_name = 'dbo.' + @membership_eval_proc_name
        
        if @rowguid is not null
        begin
			exec @retcode = @membership_eval_proc_name @rowguid = @rowguid
			if @@error <> 0 or @retcode <> 0
				goto Error
		end
		else if @marker is not null
		begin
			exec @retcode = @membership_eval_proc_name @marker = @marker
			if @@error <> 0 or @retcode <> 0
				goto Error
		end
		else
		begin
			exec @retcode = @membership_eval_proc_name
			if @@error <> 0 or @retcode <> 0
				goto Error
		end
        
        fetch next from membership_eval_proc_names into @membership_eval_proc_name
    end

    close membership_eval_proc_names
    deallocate membership_eval_proc_names

    return 0
    
Error:
    close membership_eval_proc_names
    deallocate membership_eval_proc_names

    return 1
end
GO
GRANT EXECUTE ON [sys].[sp_MSevaluate_change_membership_for_row] TO [public] AS [dbo]
GO
