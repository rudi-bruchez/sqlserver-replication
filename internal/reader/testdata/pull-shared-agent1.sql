-- Adds m_ps1's pull agent after pull-shared-setup.sql: it joins the shared
-- agent that m_ps2's call created.
SET NOCOUNT ON;
USE m_pssub;
DECLARE @srv sysname = @@SERVERNAME;
EXEC sp_addpullsubscription_agent @publisher = @srv, @publisher_db = N'Sales', @publication = N'm_ps1',
     @distributor = @srv, @subscriber_security_mode = 1, @distributor_security_mode = 1;
