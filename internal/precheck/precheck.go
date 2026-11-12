// Package precheck reads the preconditions a desired configuration relies
// on (state.Checks): the servers of the file and their versions, the source
// tables of its articles, the subscriber databases, the snapshot folders and
// the agent profiles at the distributor. The planner reads the result; it
// never reads a server itself.
package precheck

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
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
}

// noConnection is the Error of a server of the file that Conns neither
// connects nor lists as unreachable.
const noConnection = "no connection to this server"

// Run checks what the desired file relies on. It returns an error only for
// a failed read at a reached server; an unreachable server is a check.
func Run(ctx context.Context, c Conns, desired *model.Config) (*state.Checks, error) {
	out := &state.Checks{}
	publisher := desired.Publisher.Server
	distributor := publisher
	if d := desired.Distributor; d != nil && d.Server != "" {
		distributor = d.Server
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
	return out, nil
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
