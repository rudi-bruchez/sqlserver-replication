package precheck

// Every query is a SELECT. @p1 is the only parameter.
const (
	// qServer runs at each server of the file.
	qServer = `
SELECT CAST(@@SERVERNAME AS nvarchar(128)),
       CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)),
       CAST(SERVERPROPERTY('ProductMajorVersion') AS nvarchar(128)),
       CAST(SERVERPROPERTY('Edition') AS nvarchar(128))`

	// qTable runs in the publication database (Conns.Publication):
	// OBJECT_ID(N'[dbo].[Customer]') is NULL from master. @p1 is the quoted
	// schema.name. One row per column in column_id order, its key_ordinal
	// in the primary key or NULL; one row with a NULL column when the
	// object has none, and a NULL id when it does not exist. The last column
	// tells an absent object from one the login cannot see: OBJECT_ID is NULL
	// for both, and HAS_PERMS_BY_NAME on the object is 0 for both (measured
	// with a user without permissions), so a NULL id counts as an absence
	// only when the login has VIEW DEFINITION on the database.
	qTable = `
SELECT o.id,
       CAST(CASE WHEN k.object_id IS NULL THEN 0 ELSE 1 END AS int),
       c.name,
       ic.key_ordinal,
       CAST(ISNULL(HAS_PERMS_BY_NAME(NULL, N'DATABASE', N'VIEW DEFINITION'), 0) AS int)
FROM (SELECT OBJECT_ID(@p1) AS id) AS o
LEFT JOIN sys.key_constraints AS k ON k.parent_object_id = o.id AND k.type = 'PK'
LEFT JOIN sys.columns AS c ON c.object_id = o.id
LEFT JOIN sys.index_columns AS ic ON ic.object_id = o.id AND ic.index_id = k.unique_index_id
                                   AND ic.column_id = c.column_id AND ic.key_ordinal > 0
ORDER BY c.column_id`

	// qDatabase runs at a subscriber. HAS_DBACCESS is NULL for a database
	// that does not exist, also for a login denied VIEW ANY DATABASE, and 0
	// for one that exists but that the login cannot use, even when DB_ID is
	// NULL for it (measured): 0 is unchecked, never absent.
	qDatabase = `
SELECT DB_ID(@p1), HAS_DBACCESS(@p1)`

	// qFolder runs at the distributor. A directory reads file_exists 0 and
	// file_is_a_directory 1 (measured).
	qFolder = `
SELECT CAST(file_is_a_directory AS int) FROM sys.dm_os_file_exists(@p1)`

	// qProfiles runs at the distributor: every agent profile, system ones
	// included.
	qProfiles = `
SELECT profile_name, agent_type
FROM msdb.dbo.MSagent_profiles
ORDER BY agent_type, profile_name`
)
