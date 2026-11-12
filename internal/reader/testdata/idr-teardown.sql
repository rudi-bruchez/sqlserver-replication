-- Removes what idr-setup.sql creates; idempotent.
SET NOCOUNT ON;
USE Sales;
IF EXISTS (SELECT 1 FROM dbo.syspublications WHERE name = N'm_idr')
    EXEC sp_droppublication @publication = N'm_idr';
DROP TABLE IF EXISTS dbo.m_id0, dbo.m_idm, dbo.m_idn;
