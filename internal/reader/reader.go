// Package reader reads the configuration of a transactional publication
// database from the publisher and its distributor, and builds the declarative
// model. It only runs SELECT statements.
package reader

import (
	"context"
	"database/sql"
	"fmt"
	"regexp"
	"sort"
	"strings"

	"github.com/rudi-bruchez/sqlserver-replication/internal/decode"
	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
)

// Source groups the two connections an export needs.
type Source struct {
	// Publisher is connected to the publication database.
	Publisher *sql.DB
	// Distributor is connected to the distributor instance, any database.
	Distributor *sql.DB
	// Database is the publication database name.
	Database string
	// PublisherName overrides the publisher name used to look the publisher
	// up at the distributor. Empty means @@SERVERNAME of the publisher.
	PublisherName string
}

// DistributorName returns the distributor registered at the publisher.
func DistributorName(ctx context.Context, publisher *sql.DB) (string, error) {
	var name string
	err := publisher.QueryRowContext(ctx, qDistributorName).Scan(&name)
	if err == sql.ErrNoRows {
		return "", fmt.Errorf("the publisher has no distributor configured")
	}
	return name, err
}

// Export reads the whole configuration of the publication database.
func Export(ctx context.Context, src Source) (*model.Config, error) {
	e := &exporter{ctx: ctx, src: src}
	if err := e.run(); err != nil {
		return nil, err
	}
	return e.cfg, nil
}

type exporter struct {
	ctx context.Context
	src Source
	cfg *model.Config

	dist        string // quoted distribution database name
	servers     string // server name table at the distributor
	publisherID int

	pubIndex     map[int]int      // pubid → index in cfg.Publications
	articleNames map[int][]string // pubid → article names, sorted
	profiles     map[int]profileRow
	usedProfiles map[int]bool
	warned       map[string]bool
}

type profileRow struct {
	name        string
	agentType   int
	userDefined bool
	description string
	isDefault   bool
}

// warn records a warning once, however many rows raise it.
func (e *exporter) warn(format string, args ...any) {
	w := fmt.Sprintf(format, args...)
	if e.warned[w] {
		return
	}
	e.warned[w] = true
	e.cfg.Warnings = append(e.cfg.Warnings, w)
}

func (e *exporter) run() error {
	e.cfg = &model.Config{Version: model.FormatVersion}
	e.usedProfiles = map[int]bool{}
	e.warned = map[string]bool{}

	name := e.src.PublisherName
	if name == "" {
		if err := e.src.Publisher.QueryRowContext(e.ctx, qServerName).Scan(&name); err != nil {
			return fmt.Errorf("reading @@SERVERNAME: %w", err)
		}
	}
	e.cfg.Publisher = model.Publisher{Server: name, Database: e.src.Database}

	steps := []struct {
		what string
		fn   func() error
	}{
		{"distributor", e.readDistributor},
		{"agent profiles", e.readProfiles},
		{"publications", e.readPublications},
		{"articles", e.readArticles},
		{"subscriptions", e.readSubscriptions},
		{"log reader agent", e.readLogReaderAgent},
		{"snapshot agents", e.readSnapshotAgents},
		{"distribution agents", e.readDistributionAgents},
		{"agent profile parameters", e.collectProfiles},
	}
	for _, s := range steps {
		if err := s.fn(); err != nil {
			return fmt.Errorf("reading %s: %w", s.what, err)
		}
	}
	return nil
}

// distQuery substitutes the distribution database and server table names.
func (e *exporter) distQuery(q string) string {
	return strings.NewReplacer("{dist}", e.dist, "{servers}", e.servers).Replace(q)
}

func (e *exporter) readDistributor() error {
	d := &e.cfg.Distributor
	db := e.src.Distributor
	if err := db.QueryRowContext(e.ctx, qServerName).Scan(&d.Server); err != nil {
		return err
	}

	var security, trusted int
	var publisherType string
	err := db.QueryRowContext(e.ctx, qDistPublisher, e.cfg.Publisher.Server).Scan(
		&d.Database, &d.WorkingDirectory, &security, &d.PublisherConnection.Login, &trusted, &publisherType)
	if err == sql.ErrNoRows {
		return fmt.Errorf("publisher %q is not registered in msdb.dbo.MSdistpublishers at %s; "+
			"if the publication database is in an availability group, pass the original publisher name",
			e.cfg.Publisher.Server, d.Server)
	}
	if err != nil {
		return fmt.Errorf("msdb.dbo.MSdistpublishers at %s (is it a distributor?): %w", d.Server, err)
	}
	d.PublisherConnection.Security = decode.SecurityMode(security)
	if security == 0 {
		d.PublisherConnection.PasswordSecret = "publisher/" + e.cfg.Publisher.Server
	}
	d.Trusted = trusted != 0
	if publisherType != "" && !strings.EqualFold(publisherType, "MSSQLSERVER") {
		e.warn("publisher type %s is out of scope", publisherType)
	}
	e.dist = quoteName(d.Database)

	err = db.QueryRowContext(e.ctx, qDistributionDB, d.Database).Scan(
		&d.MinRetentionHours, &d.MaxRetentionHours, &d.HistoryRetentionHours)
	if err != nil {
		return fmt.Errorf("msdb.dbo.MSdistributiondbs: %w", err)
	}

	rows, err := db.QueryContext(e.ctx, qDistributorProperties)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var k, v string
		if err := rows.Scan(&k, &v); err != nil {
			return err
		}
		if d.Properties == nil {
			d.Properties = map[string]string{}
		}
		d.Properties[k] = v
	}
	if err := rows.Err(); err != nil {
		return err
	}

	var hasReplServers int
	if err := db.QueryRowContext(e.ctx, qHasReplServers, e.dist+".dbo.MSreplservers").Scan(&hasReplServers); err != nil {
		return err
	}
	if hasReplServers == 1 {
		e.servers = e.dist + ".dbo.MSreplservers"
	} else {
		e.servers = fallbackServers
	}
	err = db.QueryRowContext(e.ctx, e.distQuery(qServerID), e.cfg.Publisher.Server).Scan(&e.publisherID)
	if err == sql.ErrNoRows {
		return fmt.Errorf("publisher %q not found in the server table of %s", e.cfg.Publisher.Server, d.Database)
	}
	return err
}

func (e *exporter) readProfiles() error {
	e.profiles = map[int]profileRow{}
	rows, err := e.src.Distributor.QueryContext(e.ctx, qAgentProfiles)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var id, agentType, typ, def int
		var p profileRow
		if err := rows.Scan(&id, &p.name, &agentType, &typ, &p.description, &def); err != nil {
			return err
		}
		p.agentType, p.userDefined, p.isDefault = agentType, typ == 1, def != 0
		e.profiles[id] = p
	}
	return rows.Err()
}

// profileName resolves an agent profile id and records it for export.
func (e *exporter) profileName(id int) string {
	if id == 0 {
		return ""
	}
	p, ok := e.profiles[id]
	if !ok {
		e.warn("agent profile id %d not found in msdb.dbo.MSagent_profiles", id)
		return ""
	}
	e.usedProfiles[id] = true
	return p.name
}

// collectProfiles exports the user-defined profiles used by an exported agent,
// and the user-defined profiles marked as default, which apply to agents with
// no explicit profile.
func (e *exporter) collectProfiles() error {
	params := map[int]map[string]string{}
	rows, err := e.src.Distributor.QueryContext(e.ctx, qAgentParameters)
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var id int
		var k, v string
		if err := rows.Scan(&id, &k, &v); err != nil {
			return err
		}
		if params[id] == nil {
			params[id] = map[string]string{}
		}
		params[id][k] = v
	}
	if err := rows.Err(); err != nil {
		return err
	}

	for id, p := range e.profiles {
		if !p.userDefined || !(e.usedProfiles[id] || p.isDefault) {
			continue
		}
		if !inScopeAgentType(p.agentType) {
			continue
		}
		e.cfg.AgentProfiles = append(e.cfg.AgentProfiles, model.AgentProfile{
			Name:        p.name,
			AgentType:   decode.AgentType(p.agentType),
			Description: p.description,
			Default:     p.isDefault,
			Parameters:  params[id],
		})
	}
	sort.Slice(e.cfg.AgentProfiles, func(i, j int) bool {
		a, b := e.cfg.AgentProfiles[i], e.cfg.AgentProfiles[j]
		if a.AgentType != b.AgentType {
			return a.AgentType < b.AgentType
		}
		return a.Name < b.Name
	})
	return nil
}

func inScopeAgentType(t int) bool { return t == 1 || t == 2 || t == 3 }

// publication returns the exported publication with the given pubid.
func (e *exporter) publication(pubid int) *model.Publication {
	i, ok := e.pubIndex[pubid]
	if !ok {
		return nil
	}
	return &e.cfg.Publications[i]
}

func (e *exporter) publicationByName(name string) *model.Publication {
	for i := range e.cfg.Publications {
		// Publication names are copied verbatim to the distribution tables;
		// an exact match stays right in a case-sensitive database.
		if e.cfg.Publications[i].Name == name {
			return &e.cfg.Publications[i]
		}
	}
	return nil
}

var passwordArg = regexp.MustCompile(`(?i)(-\w*password\s+)("[^"]*"|\S+)`)

// maskPasswords hides the value of any -*Password argument of an agent
// command line.
func maskPasswords(cmd string) string {
	return passwordArg.ReplaceAllString(cmd, "${1}********")
}

// quoteName quotes an identifier the way QUOTENAME does.
func quoteName(s string) string {
	return "[" + strings.ReplaceAll(s, "]", "]]") + "]"
}
