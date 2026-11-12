// Package precheck reads the preconditions a desired configuration relies
// on (state.Checks): the servers of the file and their versions, the source
// tables of its articles, the subscriber databases, the snapshot folders,
// the agent profiles at the distributor, the msdb job permission and SQL
// Server Agent where apply runs job operations (R55, R56), the LSN of each
// subscription initialized from one (R57) and the destination schemas at
// the subscribers (R59). The planner reads the result; it never reads a
// server itself.
package precheck

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"

	mssql "github.com/microsoft/go-mssqldb"

	"github.com/rudi-bruchez/sqlserver-replication/internal/decode"
	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/state"
)

// Conns is the connections Run reads through.
type Conns struct {
	Publisher   *sql.DB // the publisher, master: qServer
	Publication *sql.DB // the publisher, connected to the publication database: qTable
	Distributor *sql.DB
	Subscribers map[string]*sql.DB // matched case-insensitively, as the reader's subscriberConn
	Unreachable map[string]string  // server name to the error that kept it out
	// DistributorServer is the distributor's name as the caller resolved
	// it, used when not empty; otherwise the file's, else the publisher.
	// Without it, a file with no distributor section and a remote
	// distributor would check the publisher in the distributor's role.
	DistributorServer string
}

// noConnection is the Error of a server of the file that Conns neither
// connects nor lists as unreachable.
const noConnection = "no connection to this server"

// Run checks what the desired file relies on. It returns an error only for
// a failed read at a reached server; an unreachable server is a check, and
// so is a read the login is refused where a check says so. current is the
// configuration read from the servers, nil when there is none: the
// distributor's working directory is checked from it when the file omits it
// (R59 minor 12).
func Run(ctx context.Context, c Conns, desired, current *model.Config) (*state.Checks, error) {
	out := &state.Checks{}
	publisher := desired.Publisher.Server
	distributor := publisher
	if d := desired.Distributor; d != nil && d.Server != "" {
		distributor = d.Server
	}
	if c.DistributorServer != "" {
		distributor = c.DistributorServer
	}

	// The servers, each once whatever its roles (R7: names compare without
	// regard to case), read through the connection of its first role, which
	// then serves its other roles.
	reached := map[string]*sql.DB{}
	index := map[string]int{} // lower-cased name to its ServerCheck
	server := func(name string, db *sql.DB) error {
		if name == "" {
			return nil
		}
		if i, ok := index[strings.ToLower(name)]; ok {
			return ownServer(ctx, &out.Servers[i], reached[strings.ToLower(name)], db)
		}
		index[strings.ToLower(name)] = len(out.Servers)
		sc := state.ServerCheck{Name: name}
		if e, ok := unreachable(c.Unreachable, name); ok {
			sc.Error = e
		} else if db == nil {
			sc.Error = noConnection
		} else {
			if err := readServer(ctx, db, &sc); err != nil {
				return err
			}
			sc.Reachable = true
			reached[strings.ToLower(name)] = db
		}
		out.Servers = append(out.Servers, sc)
		return nil
	}
	if err := server(publisher, c.Publisher); err != nil {
		return nil, err
	}
	if err := server(distributor, c.Distributor); err != nil {
		return nil, err
	}
	for _, p := range desired.Publications {
		for _, s := range p.Subscriptions {
			if err := server(s.Subscriber, subscriberConn(c.Subscribers, s.Subscriber)); err != nil {
				return nil, err
			}
		}
	}
	// Every other server of Conns, connected or not: a pull subscription
	// removed from the file is dropped at a subscriber the file no longer
	// names, which Build checks like the file's (Task 18 fix round 1).
	var others []string
	for name := range c.Subscribers {
		others = append(others, name)
	}
	for name := range c.Unreachable {
		others = append(others, name)
	}
	sort.Strings(others)
	for _, name := range others {
		if err := server(name, subscriberConn(c.Subscribers, name)); err != nil {
			return nil, err
		}
	}

	// The source tables, in the publication database.
	if reached[strings.ToLower(publisher)] != nil && c.Publication != nil {
		var dbName string
		if err := c.Publication.QueryRowContext(ctx, qDatabaseName).Scan(&dbName); err != nil {
			return nil, fmt.Errorf("%s: publication database: %w", publisher, err)
		}
		if !strings.EqualFold(dbName, desired.Publisher.Database) {
			return nil, fmt.Errorf("%s: the publication connection is in database %s, not %s", publisher, dbName, desired.Publisher.Database)
		}
		seenTable := map[string]bool{}
		for _, p := range desired.Publications {
			for _, a := range p.Articles {
				k := strings.ToLower(a.Source.Schema + "." + a.Source.Name)
				if seenTable[k] {
					continue
				}
				seenTable[k] = true
				tc, err := readTable(ctx, c.Publication, a.Source.Schema, a.Source.Name)
				if err != nil {
					return nil, fmt.Errorf("%s: table %s.%s: %w", publisher, a.Source.Schema, a.Source.Name, err)
				}
				out.Tables = append(out.Tables, tc)
			}
		}
	}

	// The subscriber databases.
	seenDB := map[string]bool{}
	for _, p := range desired.Publications {
		for _, s := range p.Subscriptions {
			k := strings.ToLower(s.Subscriber + "/" + s.Database)
			if seenDB[k] {
				continue
			}
			seenDB[k] = true
			dc := state.DatabaseCheck{Server: s.Subscriber, Database: s.Database}
			if db := reached[strings.ToLower(s.Subscriber)]; db != nil {
				// The subscriber's own connection when there is one, also
				// when the server plays another role (the lab's REPLLAB).
				if own := subscriberConn(c.Subscribers, s.Subscriber); own != nil {
					db = own
				}
				if err := readDatabase(ctx, db, &dc); err != nil {
					return nil, fmt.Errorf("%s: database %s: %w", s.Subscriber, s.Database, err)
				}
			}
			out.SubscriberDatabases = append(out.SubscriberDatabases, dc)
		}
	}

	// The snapshot folders and the profiles, at the distributor.
	var folders []string
	if d := desired.Distributor; d != nil && d.WorkingDirectory != nil && *d.WorkingDirectory != "" {
		folders = append(folders, *d.WorkingDirectory)
	} else if current != nil && current.Distributor != nil && current.Distributor.WorkingDirectory != nil && *current.Distributor.WorkingDirectory != "" {
		// The plan checks the folder the omitted working directory keeps.
		folders = append(folders, *current.Distributor.WorkingDirectory)
	}
	for _, p := range desired.Publications {
		if p.Snapshot != nil && p.Snapshot.AltFolder != nil && *p.Snapshot.AltFolder != "" {
			folders = append(folders, *p.Snapshot.AltFolder)
		}
	}
	dist := reached[strings.ToLower(distributor)]
	seenFolder := map[string]bool{}
	for _, f := range folders {
		if seenFolder[f] {
			continue
		}
		seenFolder[f] = true
		fc := state.FolderCheck{Server: distributor, Path: f}
		if dist != nil {
			var dir int
			if err := dist.QueryRowContext(ctx, qFolder, f).Scan(&dir); err != nil {
				return nil, fmt.Errorf("%s: folder %s: %w", distributor, f, err)
			}
			fc.Checked, fc.Exists = true, dir == 1
		}
		out.Folders = append(out.Folders, fc)
	}
	if dist != nil {
		profiles, err := readProfiles(ctx, dist)
		if err != nil {
			return nil, fmt.Errorf("%s: agent profiles: %w", distributor, err)
		}
		out.Profiles = profiles
	}

	// The job permission and SQL Server Agent (R55, R56), at the
	// distributor and at each subscriber: apply runs its job operations
	// there.
	roles := map[string]bool{strings.ToLower(distributor): true}
	for _, p := range desired.Publications {
		for _, s := range p.Subscriptions {
			roles[strings.ToLower(s.Subscriber)] = true
		}
	}
	for _, name := range others {
		roles[strings.ToLower(name)] = true
	}
	for _, sc := range out.Servers {
		if !roles[strings.ToLower(sc.Name)] {
			continue
		}
		jp := state.JobPermissionCheck{Server: sc.Name}
		ag := state.AgentServiceCheck{Server: sc.Name, Detail: "not reached: " + sc.Error}
		if db := roleConn(c, reached, distributor, sc.Name); db != nil {
			if err := readJobPermission(ctx, db, &jp); err != nil {
				return nil, fmt.Errorf("%s: msdb job permission: %w", sc.Name, err)
			}
			if err := readAgent(ctx, db, &ag); err != nil {
				return nil, fmt.Errorf("%s: SQL Server Agent: %w", sc.Name, err)
			}
		}
		out.JobPermissions = append(out.JobPermissions, jp)
		out.Agents = append(out.Agents, ag)
	}

	// The LSN of each subscription initialized from one (R57).
	if err := readLSNs(ctx, c, reached, desired, out); err != nil {
		return nil, err
	}

	// The destination schemas, at each subscriber database that receives
	// the articles (R59 minor 7).
	seenSchema := map[string]bool{}
	for _, p := range desired.Publications {
		for _, a := range p.Articles {
			schema := destinationSchema(&a)
			for _, s := range p.Subscriptions {
				if !covers(&s, a.Name) {
					continue
				}
				k := strings.ToLower(s.Subscriber + "/" + s.Database + "/" + schema)
				if seenSchema[k] {
					continue
				}
				seenSchema[k] = true
				sc := state.SchemaCheck{Server: s.Subscriber, Database: s.Database, Schema: schema}
				dc := subscriberDatabase(out, s.Subscriber, s.Database)
				if db := subscriberDB(c, reached, s.Subscriber); db != nil && dc != nil && dc.Checked && dc.Exists {
					var n int
					q := strings.Replace(qSchema, "{db}", quoteName(s.Database), 1)
					if err := db.QueryRowContext(ctx, q, schema).Scan(&n); err != nil {
						if !refused(err) {
							return nil, fmt.Errorf("%s: schema %s of %s: %w", s.Subscriber, schema, s.Database, err)
						}
					} else {
						sc.Checked, sc.Exists = true, n > 0
					}
				}
				out.Schemas = append(out.Schemas, sc)
			}
		}
	}
	return out, nil
}

// destinationSchema is the schema an article's table is created in at the
// subscriber, as the file gives it: its destination schema, else its source
// schema (the default of native, concurrent and the database snapshot
// methods, 11-defaults <kind>.nondbo.*), else dbo.
func destinationSchema(a *model.Article) string {
	switch {
	case a.Destination.Schema != nil && *a.Destination.Schema != "":
		return *a.Destination.Schema
	case a.Destination.Schema == nil && a.Source.Schema != "":
		return a.Source.Schema
	}
	return "dbo"
}

// covers tells whether a subscription receives an article: every article
// when it lists none.
func covers(s *model.Subscription, article string) bool {
	if len(s.Articles) == 0 {
		return true
	}
	for _, n := range s.Articles {
		if strings.EqualFold(n, article) {
			return true
		}
	}
	return false
}

func subscriberDatabase(c *state.Checks, server, database string) *state.DatabaseCheck {
	for i := range c.SubscriberDatabases {
		d := &c.SubscriberDatabases[i]
		if strings.EqualFold(d.Server, server) && strings.EqualFold(d.Database, database) {
			return d
		}
	}
	return nil
}

// subscriberDB is the connection a subscriber's databases are read through:
// its own when there is one, also when the server plays another role.
func subscriberDB(c Conns, reached map[string]*sql.DB, name string) *sql.DB {
	db := reached[strings.ToLower(name)]
	if db == nil {
		return nil
	}
	if own := subscriberConn(c.Subscribers, name); own != nil {
		return own
	}
	return db
}

// roleConn is the connection apply runs a server's job operations through:
// the distributor's for the distributor, the subscriber's own otherwise;
// nil when the server was not reached.
func roleConn(c Conns, reached map[string]*sql.DB, distributor, name string) *sql.DB {
	if reached[strings.ToLower(name)] == nil {
		return nil
	}
	if strings.EqualFold(name, distributor) && c.Distributor != nil {
		return c.Distributor
	}
	return subscriberDB(c, reached, name)
}

// refused tells a read the server refused (a permission, a missing object)
// from a failure to talk to it: the first leaves its check unchecked.
func refused(err error) bool {
	var me mssql.Error
	return errors.As(err, &me)
}

// readJobPermission reads R55's memberships and permissions.
func readJobPermission(ctx context.Context, db *sql.DB, jp *state.JobPermissionCheck) error {
	var sysadmin, operator, reads int
	if err := db.QueryRowContext(ctx, qJobPermission).Scan(&sysadmin, &operator, &reads); err != nil {
		if refused(err) {
			return nil
		}
		return err
	}
	jp.Checked, jp.Sysadmin, jp.Operator, jp.ReadsJobs = true, sysadmin == 1, operator == 1, reads == 1
	return nil
}

// readAgent reads R56's SQL Server Agent row: Running is running; no row
// is a server without the service.
func readAgent(ctx context.Context, db *sql.DB, ag *state.AgentServiceCheck) error {
	var name, status string
	err := db.QueryRowContext(ctx, qAgent).Scan(&name, &status)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		ag.Checked, ag.Detail = true, "sys.dm_server_services has no SQL Server Agent row"
	case err != nil && refused(err):
		ag.Detail = "sys.dm_server_services could not be read: " + err.Error()
	case err != nil:
		return err
	default:
		ag.Checked, ag.Running, ag.Detail = true, status == "Running", name+": "+status
	}
	return nil
}

// readLSNs checks the LSN of each subscription of the file initialized from
// one (R57): parsed, then against the end of the publication database's
// log at the publisher and the last_lsn of the backup the subscriber
// database was last restored from, which must be a backup of the
// publication database (its database_name and server_name, without regard
// to case: 20-apply AP.lsn.backupset_database). Nothing is passed to a
// server: a wrong LSN accepted by sp_addsubscription stops every
// subscription of the database (lab/README.md, "Initialization without a
// snapshot").
func readLSNs(ctx context.Context, c Conns, reached map[string]*sql.DB, desired *model.Config, out *state.Checks) error {
	publisher, pubDB := desired.Publisher.Server, desired.Publisher.Database
	logEnd, logEndErr, logEndRead := [10]byte{}, "", false
	readLogEnd := func() error {
		if logEndRead {
			return nil
		}
		logEndRead = true
		db := reached[strings.ToLower(publisher)]
		if db == nil {
			logEndErr = "the publisher " + publisher + " was not reached"
			return nil
		}
		var e sql.NullString
		err := db.QueryRowContext(ctx, qLogEnd, pubDB).Scan(&e)
		switch {
		case errors.Is(err, sql.ErrNoRows) || err == nil && !e.Valid:
			logEndErr = "the end of the log of " + pubDB + " was not read"
		case err != nil && refused(err):
			logEndErr = "the end of the log of " + pubDB + " could not be read: " + err.Error()
		case err != nil:
			return fmt.Errorf("%s: log end of %s: %w", publisher, pubDB, err)
		default:
			b, perr := lsnFromLogEnd(e.String)
			if perr != nil {
				logEndErr = perr.Error()
			}
			logEnd = b
		}
		return nil
	}
	for _, p := range desired.Publications {
		for _, s := range p.Subscriptions {
			if s.Initialization == nil || *s.Initialization != "lsn" {
				continue
			}
			lc := state.LSNCheck{Publication: p.Name, Subscriber: s.Subscriber, Database: s.Database}
			if s.LSN != nil {
				lc.LSN = *s.LSN
			}
			if err := checkSubscriptionLSN(ctx, c, reached, desired, &lc, readLogEnd, &logEnd, &logEndErr); err != nil {
				return err
			}
			out.LSNs = append(out.LSNs, lc)
		}
	}
	return nil
}

func checkSubscriptionLSN(ctx context.Context, c Conns, reached map[string]*sql.DB, desired *model.Config, lc *state.LSNCheck,
	readLogEnd func() error, logEnd *[10]byte, logEndErr *string) error {
	if lc.LSN == "" {
		lc.Checked, lc.Reason = true, "initialization lsn needs lsn, 0x and 20 hexadecimal digits"
		return nil
	}
	lsn, err := parseLSN(lc.LSN)
	if err != nil {
		lc.Checked, lc.Reason = true, err.Error()
		return nil
	}
	if err := readLogEnd(); err != nil {
		return err
	}
	if *logEndErr != "" {
		lc.Reason = *logEndErr
		return nil
	}
	db := subscriberDB(c, reached, lc.Subscriber)
	if db == nil {
		lc.Reason = "the subscriber " + lc.Subscriber + " was not reached"
		return nil
	}
	var last, dbName, server sql.NullString
	err = db.QueryRowContext(ctx, qRestored, lc.Database).Scan(&last, &dbName, &server)
	switch {
	case errors.Is(err, sql.ErrNoRows):
		lc.Reason = fmt.Sprintf("%s/%s has no restore history", lc.Subscriber, lc.Database)
		return nil
	case err != nil && refused(err):
		lc.Reason = fmt.Sprintf("the restore history of %s/%s could not be read: %v", lc.Subscriber, lc.Database, err)
		return nil
	case err != nil:
		return fmt.Errorf("%s: restore history of %s: %w", lc.Subscriber, lc.Database, err)
	}
	if !strings.EqualFold(dbName.String, desired.Publisher.Database) || !strings.EqualFold(server.String, desired.Publisher.Server) {
		lc.Checked, lc.Reason = true, fmt.Sprintf("%s/%s was last restored from a backup of %s/%s, not of the publication database %s/%s",
			lc.Subscriber, lc.Database, server.String, dbName.String, desired.Publisher.Server, desired.Publisher.Database)
		return nil
	}
	restored, err := lsnFromNumeric(last.String)
	if err != nil {
		lc.Reason = err.Error()
		return nil
	}
	lc.Checked = true
	lc.Valid, lc.Reason = checkLSN(lsn, restored, *logEnd)
	return nil
}

// ownServer reads the server again through the subscriber's own
// connection own, when the server was reached through another role's
// connection (the subscriber databases are read through own): when own
// answers another @@SERVERNAME than the file's name, the check keeps that
// answer, so that Build refuses it (Task 17 fix round 2, C).
func ownServer(ctx context.Context, sc *state.ServerCheck, reachedBy, own *sql.DB) error {
	if own == nil || reachedBy == nil || own == reachedBy {
		return nil
	}
	other := state.ServerCheck{Name: sc.Name}
	if err := readServer(ctx, own, &other); err != nil {
		return err
	}
	if other.ServerName != "" && !strings.EqualFold(other.ServerName, sc.Name) {
		sc.ServerName = other.ServerName
	}
	return nil
}

// readServer reads a server; ServerName stays "" when @@SERVERNAME is NULL
// (sp_dropserver without sp_addserver), which Build does not compare.
func readServer(ctx context.Context, db *sql.DB, sc *state.ServerCheck) error {
	var name, major sql.NullString
	if err := db.QueryRowContext(ctx, qServer).Scan(&name, &sc.Version, &major, &sc.Edition); err != nil {
		return fmt.Errorf("%s: server: %w", sc.Name, err)
	}
	sc.ServerName = name.String
	m, err := strconv.Atoi(major.String)
	if err != nil {
		return fmt.Errorf("%s: ProductMajorVersion %q: %w", sc.Name, major.String, err)
	}
	sc.Major = m
	return nil
}

func readTable(ctx context.Context, db *sql.DB, schema, name string) (state.TableCheck, error) {
	tc := state.TableCheck{Schema: schema, Name: name}
	rows, err := db.QueryContext(ctx, qTable, quoteName(schema)+"."+quoteName(name))
	if err != nil {
		return tc, err
	}
	defer rows.Close()
	type key struct {
		ord  int64
		name string
	}
	var keys []key
	missing := false
	for rows.Next() {
		var (
			id, ord sql.NullInt64
			pk      int
			col     sql.NullString
		)
		if err := rows.Scan(&id, &pk, &col, &ord); err != nil {
			return tc, err
		}
		if !id.Valid {
			missing = true
			continue
		}
		tc.Exists, tc.HasPrimaryKey = true, pk == 1
		if col.Valid {
			tc.Columns = append(tc.Columns, col.String)
			if ord.Valid {
				keys = append(keys, key{ord.Int64, col.String})
			}
		}
	}
	if err := rows.Err(); err != nil {
		return tc, err
	}
	if missing {
		return tc, probeTable(ctx, db, schema, name)
	}
	tc.KeyColumns = make([]string, len(keys))
	for _, k := range keys {
		if k.ord < 1 || int(k.ord) > len(keys) {
			return tc, fmt.Errorf("primary key ordinal %d of %d columns", k.ord, len(keys))
		}
		tc.KeyColumns[k.ord-1] = k.name
	}
	if len(keys) == 0 {
		tc.KeyColumns = nil
	}
	return tc, nil
}

// probeTable tells a missing table (nil) from one the login cannot see
// (an error), by selecting from it: see tableProbe.
func probeTable(ctx context.Context, db *sql.DB, schema, name string) error {
	_, err := db.ExecContext(ctx, tableProbe+quoteName(schema)+"."+quoteName(name))
	var me mssql.Error
	switch {
	case err == nil:
		return fmt.Errorf("cannot be read: OBJECT_ID is NULL but a SELECT from it succeeds")
	case errors.As(err, &me) && me.Number == 208:
		return nil
	default:
		return fmt.Errorf("cannot be read: OBJECT_ID is NULL and a SELECT from it fails: %w", err)
	}
}

// readDatabase reads a subscriber database: HAS_DBACCESS NULL is a
// database that does not exist, 1 one the login can use, 0 one it cannot
// see or use, which stays unchecked.
func readDatabase(ctx context.Context, db *sql.DB, dc *state.DatabaseCheck) error {
	var id, access sql.NullInt64
	if err := db.QueryRowContext(ctx, qDatabase, dc.Database).Scan(&id, &access); err != nil {
		return err
	}
	switch {
	case !access.Valid:
		dc.Checked, dc.Exists = true, false
	case access.Int64 == 1:
		dc.Checked, dc.Exists = true, id.Valid
	default:
		dc.Checked = false
	}
	return nil
}

func readProfiles(ctx context.Context, db *sql.DB) ([]state.ProfileCheck, error) {
	rows, err := db.QueryContext(ctx, qProfiles)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []state.ProfileCheck
	for rows.Next() {
		var (
			name string
			typ  int
		)
		if err := rows.Scan(&name, &typ); err != nil {
			return nil, err
		}
		out = append(out, state.ProfileCheck{Name: name, AgentType: decode.AgentType(typ)})
	}
	return out, rows.Err()
}

// subscriberConn returns the connection of a subscriber, matching the name
// case-insensitively: syssubscriptions.srvname is upper case while the user
// types the name as they like.
func subscriberConn(subs map[string]*sql.DB, name string) *sql.DB {
	for k, db := range subs {
		if strings.EqualFold(k, name) {
			return db
		}
	}
	return nil
}

// unreachable returns the error that kept a server out, matching the name
// case-insensitively.
func unreachable(m map[string]string, name string) (string, bool) {
	for k, e := range m {
		if strings.EqualFold(k, name) {
			return e, true
		}
	}
	return "", false
}

func quoteName(s string) string {
	return "[" + strings.ReplaceAll(s, "]", "]]") + "]"
}
