SET ANSI_NULLS OFF
GO
SET QUOTED_IDENTIFIER OFF
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_replmonitorchangepublicationthreshold]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_replmonitorchangepublicationthreshold] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_replmonitorchangepublicationthreshold]
	@publisher [sysname],
	@publisher_db [sysname],
	@publication [sysname],
	@publication_type [int],
	@metric_id [int],
	@thresholdmetricname [sysname],
	@value [int],
	@shouldalert [bit],
	@mode [tinyint]
WITH EXECUTE AS CALLER
AS
begin
	set nocount on
	declare @retcode int
				,@publication_id int
	--
	-- constants
	--
	declare @modeenable tinyint
				,@modedisable tinyint

	--
	-- initialize
	--
	select @modeenable = 1
				,@modedisable = 2
	--
	-- security check : replmonitor
	--
	if not (is_member(N'db_owner') = 1 or isnull(is_member(N'replmonitor'),0) = 1)
	begin
		raiserror(14260, 16, -1)
		return (1)
	end
	--
	-- security: Has to be executed from distribution database
	--
	if sys.fn_MSrepl_isdistdb (db_name()) != 1
	begin
		raiserror (21482, 16, -1, 'sp_replmonitorchangepublicationthreshold', 'distribution')
		return 1
	end
	--
	-- check @mode
	--
	if (@mode not in (@modeenable, @modedisable))
	begin
		raiserror(21402, 16, -1, '@mode')
		return 1
	end

	-- Get publisher without port number
	exec sys.sp_MSget_server_portinfo 
		@name = @publisher, 
		@srvname = @publisher OUTPUT

	--
	-- validate publication
	--
    select @publication_id = p.publication_id
    from dbo.MSpublications as p join MSreplservers as s
        on p.publisher_id = s.srvid
        and upper(s.srvname) = upper(@publisher)
        and p.publisher_db = @publisher_db
        and p.publication = @publication
        and p.publication_type= case when (@publication_type is null) then p.publication_type else @publication_type end
	if (@publication_id is null)
	begin
		raiserror(20026, 16, 1, @publication)
		return 1
	end
	--
	-- validate metric
	--
	if (@metric_id is null and @thresholdmetricname is null)
	begin
		raiserror(21821, 16, -1, '@metric_id', '@thresholdmetricname')
		return 1
	end
	else if (@metric_id is not null and @thresholdmetricname is null)
	begin
		select @thresholdmetricname = title
		from msdb.dbo.MSreplmonthresholdmetrics
		where metric_id = @metric_id
		if (@thresholdmetricname is null)
		begin
			raiserror(14200, 16, 1, '@metric_id')
			return 1
		end
	end
	else if (@metric_id is null and @thresholdmetricname is not null)
	begin
		select @metric_id = metric_id
		from msdb.dbo.MSreplmonthresholdmetrics
		where title = lower(@thresholdmetricname)
		if (@metric_id is null)
		begin
			raiserror(14200, 16, 2, '@thresholdmetricname')
			return 1
		end
	end
	else
	begin
		raiserror(21821, 16, -1, '@metric_id', '@thresholdmetricname')
		return 1
	end
	--
	-- proceed only if row exists
	--
	if exists (select * from dbo.MSpublicationthresholds 
		where publication_id = @publication_id 
			and metric_id = @metric_id)
	begin
		--
		-- Process according to the mode and update
		--
		if (@mode = @modeenable)
		begin
			-- enable state
			update dbo.MSpublicationthresholds
			set value = case when (@value is null) then value else @value end
				,shouldalert = case when (@shouldalert is null) then shouldalert else @shouldalert end
				,isenabled=1
			where publication_id = @publication_id 
				and metric_id = @metric_id
		end
		else
		begin
			-- disable state
			update dbo.MSpublicationthresholds
			set isenabled=0
			where publication_id = @publication_id 
				and metric_id = @metric_id
		end
		--
		-- Check if enable/disable update failed
		--
		if (@@error != 0)
			return 1
	end
	else
	begin
		raiserror(21823, 16, -1, 'enable/disable', 'MSpublicationthresholds')
		return 1
	end
	--
	-- return
	--
	return 0
end
GO
GRANT EXECUTE ON [sys].[sp_replmonitorchangepublicationthreshold] TO [public] AS [dbo]
GO
