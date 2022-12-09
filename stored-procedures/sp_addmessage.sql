SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
IF NOT EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(N'[sys].[sp_addmessage]') AND type in (N'P', N'PC'))
BEGIN
EXEC dbo.sp_executesql @statement = N'CREATE PROCEDURE [sys].[sp_addmessage] AS' 
END
GO
ALTER PROCEDURE [sys].[sp_addmessage]
	@msgnum [int],
	@severity [smallint],
	@msgtext [nvarchar](255),
	@lang [sysname],
	@with_log [varchar](5),
	@replace [varchar](7)
WITH EXECUTE AS CALLER
AS
declare @retcode int
	declare @langid	smallint,
			@msglangid smallint
	declare @islog bit

	-- Must be ServerAdmin to manage messages
	if is_srvrolemember('serveradmin') = 0
	begin
		raiserror(15247,-1,-1)
		return (1)
	end

	if @msgnum is null or @severity is null or @msgtext is null
	begin
		raiserror(15071,-1,-1)
		return (1)
	end

	-- User defined messages must be > 50000.
	if @msgnum <= 50000
	begin
		raiserror(15040,-1,-1)
		return (1)
	end

	-- Valid severity range for user defined messges is 1 to 25.
	if @severity not between 1 and 25
	begin
		raiserror(15041,-1,-1)
		return (1)
	end

	-- Verify the language
	if @lang is not null
	begin
		-- Check to see if this language is in Syslanguages.
		if not exists (select * from sys.syslanguages where name = @lang or alias = @lang)
			and @lang <> N'us_english'
		begin
			raiserror(15033,-1,-1,@lang)
			return (1)
		end
	end
	else
		select @lang = @@language

	-- Get langid from syslanguages; us_english won't exist, so use 0.
	select @langid = langid, @msglangid = msglangid
		from sys.syslanguages where name = @lang or alias = @lang

	select @langid = isnull(@langid, 0)
	select @msglangid = isnull(@msglangid, 1033)

	--  Set the event log bit accordingly
	select @islog = (case rtrim(upper(@with_log))
			when 'TRUE' then 1
			when 'FALSE' then 0
			end)
	if @islog is null
	begin
		-- @with_log must be 'TRUE' or 'FALSE' or Null
		if not (@with_log is null)
		begin
			raiserror(15271,-1,-1)
			return (1)
		end
		if @langid = 0	-- backward compatible
			select @islog = 0
	end

	if @replace is not null
	begin
		if lower(@replace) <> 'replace'
		begin
			raiserror(15043,-1,-1)
			return (1)
		end
	end

	BEGIN TRANSACTION
	-- If this message not exists, lock ID anyway
	EXEC %%ErrorMessage(ID = @msgnum).Lock(Exclusive = 1)

	-- If we're adding a non-us_english message, make sure the us_english version already exists.
	if (@langid <> 0) and not exists (select * from sys.messages$ where message_id=@msgnum and language_id = 1033)
	begin
		COMMIT TRANSACTION
		raiserror(15279,-1,-1,@lang)
		return(1)
	end

	-- If we're adding a non-us_english message, make sure that the severity matches that of the us_english version
	if (@langid <> 0 ) and not exists (select * from sys.messages$ where message_id=@msgnum and severity=@severity and language_id = 1033)
	begin
		COMMIT TRANSACTION
		declare @us_english_severity smallint
		select @us_english_severity = severity from sys.messages$ where message_id=@msgnum and language_id = 1033
		raiserror(15304,-1,-1,@lang,@us_english_severity)
		return (1)
	end

	-- Warning: If we're adding a non-us_english message, ignore @with_log
	if not (@islog is null) and (@langid <> 0)
		raiserror(15042,-1,-1)
	
	-- Does this message already exist?
	if exists (select * from sys.messages$ where message_id=@msgnum and language_id=@msglangid)
	begin
		-- if so, are we REPLACEing it?
		if lower(@replace) = 'replace'
		begin
			EXEC %%ErrorMessage(ID = @msgnum).RemoveMessage(LanguageID = @msglangid)
			-- Sync non-us_english msg severity and eventlog with us_english version
			if @langid = 0
			begin
				EXEC %%ErrorMessage(ID = @msgnum).SetSeverity(Severity = @severity)
				EXEC %%ErrorMessage(ID = @msgnum).SetEventLog(EventLog = @islog)
			end
		end
		else
		begin
			COMMIT TRANSACTION
			-- The 'replace' option wasn't specified and a msg. with the number already exists.
			raiserror(15043,-1,-1)
			return(1)
		end
	end
	else
	begin
		-- initialize us_english version
		if @langid = 0
			EXEC %%ErrorMessage().NewError(ID = @msgnum, Severity = @severity, EventLog = @islog)
	end

	-- set default for islog if not set for trigger firing purposes
	if @with_log is null
	begin
		set @with_log = 'FALSE'
	end

	declare @msg_str nvarchar(50)
	set @msg_str = @msgnum

	-- Update/replace the message
	EXEC %%ErrorMessage(ID = @msgnum).NewMessage(LanguageID = @msglangid, Description = @msgtext)

	-- EMDEventType(x_eet_Create_Message), EMDUniversalClass( x_eunc_Type), src major id, src minor id, src name
	-- -1 means ignore target stuff, target major id, target minor id, target name,
	-- # of parameters, 5 parameters
	EXEC %%System().FireTrigger(ID = 227, ID = 106, ID = @msgnum, ID = 0, Value = @msg_str,
		ID = -1, ID = 0, ID = 0, Value = NULL, 
		ID = 6, Value = @msgnum, Value = @severity, Value = @msgtext, Value = @lang, Value = @with_log, Value = @replace, Value = NULL)

	COMMIT TRANSACTION

	return (0) -- sp_addmessage
GO
GRANT EXECUTE ON [sys].[sp_addmessage] TO [public] AS [dbo]
GO
