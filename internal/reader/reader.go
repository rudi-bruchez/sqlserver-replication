// Package reader reads the configuration of a transactional publication
// database from the publisher and its distributor, and builds the declarative
// model. It only runs SELECT statements.
package reader

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strings"

	"github.com/rudi-bruchez/sqlserver-replication/internal/decode"
	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/state"
)

// Source groups the connections a read needs.
type Source struct {
	// Publisher is connected to the publication database.
	Publisher *sql.DB
	// Distributor is connected to the distributor instance, any database. It
	// may be nil when the probe finds no distributor.
	Distributor *sql.DB
	// Database is the publication database name. Read replaces it by
	// Probe.Name, the stored name, when the probe has one.
	Database string
	// PublisherName overrides the publisher name used to look the publisher
	// up at the distributor. Empty means @@SERVERNAME of the publisher.
	PublisherName string
	// Probe is the result of Probe on the publisher.
	Probe PublisherProbe
	// Subscribers holds a connection to master of each subscriber that can
	// be read, keyed by the server name as the user typed it. A pull
	// subscription is read at its subscriber; one whose subscriber is not
	// here is reported unreadable. Keys are matched case-insensitively
	// (subscriberConn).
	Subscribers map[string]*sql.DB
	// Facts asks for the observed runtime facts (Result.Facts). Without it
	// no facts query runs: no job state, no history, no profile uses.
	Facts bool
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

// subscriberQuery returns qPullSubscription for a subscription database.
func subscriberQuery(database string) string {
	return strings.ReplaceAll(qPullSubscription, "{subdb}", quoteName(database))
}

// PullSubscribers returns the servers of the pull subscriptions of the
// publication database pub is connected to, sorted. They are read at their
// subscriber, so the caller opens them before Read. A database never
// published has no dbo.syssubscriptions: error 208 means no pull
// subscription, not an error (measured on the lab: a compile error, it
// arrives at QueryContext).
func PullSubscribers(ctx context.Context, pub *sql.DB) ([]string, error) {
	rows, err := pub.QueryContext(ctx, pullSubscribersQuery)
	if errorNumber(err) == 208 {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("reading the pull subscribers: %w", err)
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			return nil, err
		}
		out = append(out, name)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("reading the pull subscribers: %w", err)
	}
	sort.Strings(out)
	return out, nil
}

// DistributionDB returns the distribution database the distributor dist
// records for publisher (msdb.dbo.MSdistpublishers, names compared without
// regard to case), "" when it records none. apply reads it before its read
// to take the distributor lock (R45) for a file that declares
// agent_profiles without a distributor section.
func DistributionDB(ctx context.Context, dist *sql.DB, publisher string) (string, error) {
	var db, workingDirectory, login, publisherType string
	var security, trusted, hasStorage int
	err := dist.QueryRowContext(ctx, qDistPublisher, publisher).Scan(
		&db, &workingDirectory, &security, &login, &trusted, &publisherType, &hasStorage)
	if err == sql.ErrNoRows {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("msdb.dbo.MSdistpublishers: %w", err)
	}
	return db, nil
}

// PublisherProbe is what the publisher says about itself and the publication
// database, before any connection to the database or the distributor.
type PublisherProbe struct {
	Distributor string
	State       string
	Standby     bool
	Published   bool
	// MergePublished is true when the database is published for merge
	// replication.
	MergePublished bool
	// Name is the database name as sys.databases stores it, which may differ
	// in case from the name typed: Read uses it from the probe on, because
	// the distribution tables and a subscriber may compare it under a
	// case-sensitive collation.
	Name string
	// ReadOnly is sys.databases.is_read_only: the export reads such a
	// database, a plan cannot run in it (Writable).
	ReadOnly bool
}

// Probe queries the publisher, through a connection to its master database.
func Probe(ctx context.Context, publisher *sql.DB, database string) (PublisherProbe, error) {
	var p PublisherProbe
	err := publisher.QueryRowContext(ctx, qProbe, database).Scan(
		&p.Distributor, &p.State, &p.Standby, &p.Published, &p.MergePublished, &p.Name, &p.ReadOnly)
	if err == sql.ErrNoRows {
		return p, fmt.Errorf("database %q not found at the publisher", database)
	}
	return p, err
}

// Start decides what the export is. It returns an error when the database
// cannot be read, empty when the export is the empty configuration, and the
// findings that say why.
func (p PublisherProbe) Start() (empty bool, findings []model.Finding, err error) {
	if p.State != "ONLINE" {
		return false, nil, fmt.Errorf("database is %s", strings.ToLower(p.State))
	}
	if p.Standby {
		return false, nil, fmt.Errorf("database is in standby")
	}
	switch {
	case p.Distributor == "":
		empty = true
		findings = append(findings, model.Finding{Kind: model.FindingNote, Path: "distributor",
			Message: "no distributor is configured at the publisher"})
	case !p.Published:
		empty = true
		findings = append(findings, model.Finding{Kind: model.FindingNote, Path: "publications",
			Message: "the database is not enabled for transactional or snapshot publishing"})
	}
	// Merge publications are out of scope even beside transactional ones:
	// plan 3 refuses the database rather than ignore them.
	if p.MergePublished {
		findings = append(findings, model.Finding{Kind: model.FindingOutOfScope,
			Message: "the database is published for merge replication"})
	}
	return empty, findings, nil
}

// Writable returns an error when the publication database is read only, as
// Start does for an offline one. The export reads such a database; a plan's
// first call that writes fails with 3906, after R24's job_disable has run
// and left the snapshot job disabled (measured by the final review of plan
// 3), so plan refuses it before any operation.
func (p PublisherProbe) Writable() error {
	if p.ReadOnly {
		return fmt.Errorf("database is read only")
	}
	return nil
}

// Result is what Read returns.
type Result struct {
	Config *model.Config
	// Facts are the observed runtime facts the planner needs beside the
	// configuration; they are never part of the declarative file. Nil
	// unless Source.Facts is set.
	Facts *state.Facts
}

// Read reads the whole configuration of the publication database, or the
// empty configuration when the probe says there is nothing to read.
func Read(ctx context.Context, src Source) (*Result, error) {
	// A zero probe would read as a database in no state at all; Start
	// refuses it only after the first query.
	if src.Probe.State == "" {
		return nil, errors.New("reader: Source.Probe is not set")
	}
	if src.Probe.Name != "" {
		src.Database = src.Probe.Name
	}
	e := &exporter{ctx: ctx, src: src}
	if err := e.run(); err != nil {
		return nil, err
	}
	return &Result{Config: e.cfg, Facts: e.facts}, nil
}

type exporter struct {
	ctx   context.Context
	src   Source
	cfg   *model.Config
	facts *state.Facts

	dist        string // quoted distribution database name
	servers     string // server name table at the distributor
	replServers bool   // the distribution database has MSreplservers
	replProbed  bool   // replServers is decided
	publisherID int

	pubIndex     map[int]int      // pubid → index in cfg.Publications
	articleNames map[int][]string // pubid → article names, sorted
	profiles     map[int]profileRow
	usedProfiles map[int]bool
	found        map[string]bool
	secrets      secrets
}

type profileRow struct {
	name        string
	agentType   int
	userDefined bool
	description string
	isDefault   bool
}

// find records a finding once, however many rows raise it.
func (e *exporter) find(kind, path, format string, args ...any) {
	f := model.Finding{Kind: kind, Path: path, Message: fmt.Sprintf(format, args...)}
	k := f.Kind + "\x00" + f.Path + "\x00" + f.Message
	if e.found[k] {
		return
	}
	e.found[k] = true
	e.cfg.Findings = append(e.cfg.Findings, f)
}

// secret returns the secret name of a source, noting a collision at path.
func (e *exporter) secret(path, kind string, parts ...string) string {
	n, f := e.secrets.name(kind, parts...)
	if f != nil {
		e.find(f.Kind, path, "%s", f.Message)
	}
	return n
}

// publicationPath, articlePath and subscriptionPath build finding paths.
func publicationPath(name string) string {
	return "publications" + model.Element(model.Publication{Name: name}.Key())
}

func articlePath(pub, name string) string {
	return model.Join(publicationPath(pub), "articles") + model.Element(model.Article{Name: name}.Key())
}

func subscriptionPath(pub, subscriber, database string) string {
	return model.Join(publicationPath(pub), "subscriptions") +
		model.Element(model.Subscription{Subscriber: subscriber, Database: database}.Key())
}

func (e *exporter) run() error {
	e.cfg = &model.Config{Version: model.FormatVersion}
	if e.src.Facts {
		e.facts = newFacts()
	}
	e.usedProfiles = map[int]bool{}
	e.found = map[string]bool{}

	name := e.src.PublisherName
	if name == "" {
		if err := e.src.Publisher.QueryRowContext(e.ctx, qServerName).Scan(&name); err != nil {
			return fmt.Errorf("reading @@SERVERNAME: %w", err)
		}
	}
	e.cfg.Publisher = model.Publisher{Server: name, Database: e.src.Database}

	empty, findings, err := e.src.Probe.Start()
	if err != nil {
		return err
	}
	for _, f := range findings {
		e.find(f.Kind, f.Path, "%s", f.Message)
	}
	if err := e.readSyncWithBackup(); err != nil {
		return fmt.Errorf("reading sync with backup: %w", err)
	}
	if err := e.readReadAt(); err != nil {
		return fmt.Errorf("reading the distributor time: %w", err)
	}
	if empty {
		// What exists at the distributor is read even with no publication:
		// plan 3 must not create it again. The agent profiles live in msdb
		// and are shared by every publisher.
		if e.src.Probe.Distributor == "" || e.src.Distributor == nil {
			return nil
		}
		steps := []step{
			{"distributor", func() error { return e.readDistributor(true) }},
			{"agent profiles", e.readProfiles},
			{"agent profile parameters", e.collectProfiles},
		}
		if e.src.Facts {
			steps = append(steps, step{"profile uses", e.readProfileUses},
				step{"publisher databases", e.readPublisherDatabases},
				step{"profile templates", e.readProfileTemplates})
		}
		return runSteps(steps)
	}

	return runSteps([]step{
		{"distributor", func() error { return e.readDistributor(false) }},
		{"agent profiles", e.readProfiles},
		{"publications", e.readPublications},
		{"articles", e.readArticles},
		{"subscriptions", e.readSubscriptions},
		{"log reader agent", e.readLogReaderAgent},
		{"snapshot agents", e.readSnapshotAgents},
		{"distribution agents", e.readDistributionAgents},
		{"agent profile parameters", e.collectProfiles},
		{"facts", e.readFacts},
	})
}

// step is one read of run, named for its error.
type step struct {
	what string
	fn   func() error
}

func runSteps(steps []step) error {
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

// readDistributor reads the distributor section. With lenient, a publisher
// that the distributor does not know gives the server name and a note.
func (e *exporter) readDistributor(lenient bool) error {
	d := &model.Distributor{}
	e.cfg.Distributor = d
	db := e.src.Distributor
	if err := db.QueryRowContext(e.ctx, qServerName).Scan(&d.Server); err != nil {
		return err
	}

	var security, trusted, hasStorage int
	var workingDirectory, login, publisherType string
	err := db.QueryRowContext(e.ctx, qDistPublisher, e.cfg.Publisher.Server).Scan(
		&d.Database, &workingDirectory, &security, &login, &trusted, &publisherType, &hasStorage)
	if err == sql.ErrNoRows && lenient {
		e.find(model.FindingNote, "distributor", "publisher %q is not registered at the distributor", e.cfg.Publisher.Server)
		return nil
	}
	if err == sql.ErrNoRows {
		return fmt.Errorf("publisher %q is not registered in msdb.dbo.MSdistpublishers at %s; "+
			"if the publication database is in an availability group, pass the original publisher name",
			e.cfg.Publisher.Server, d.Server)
	}
	if err != nil {
		return fmt.Errorf("msdb.dbo.MSdistpublishers at %s (is it a distributor?): %w", d.Server, err)
	}
	d.WorkingDirectory = model.Ptr(workingDirectory)
	d.PublisherConnection = &model.Connection{Security: model.Ptr(decode.SecurityMode(security)), Login: model.Ptr(login)}
	if security == 0 {
		d.PublisherConnection.PasswordSecret = model.Ptr(e.secret("distributor.publisher_connection.password_secret",
			"SQL", e.cfg.Publisher.Server, login))
	}
	d.Trusted = model.Ptr(trusted != 0)
	if hasStorage != 0 {
		d.StorageConnectionStringSecret = model.Ptr(e.secret("distributor.storage_connection_string_secret",
			"STORAGE", e.cfg.Publisher.Server))
	}
	if publisherType != "" && !strings.EqualFold(publisherType, "MSSQLSERVER") {
		e.find(model.FindingOutOfScope, "distributor", "publisher type %s is out of scope", publisherType)
	}
	e.dist = quoteName(d.Database)

	var minRetention, maxRetention, historyRetention, deleteXact, deleteCmd int
	err = db.QueryRowContext(e.ctx, qDistributionDB, d.Database).Scan(
		&minRetention, &maxRetention, &historyRetention, &deleteXact, &deleteCmd)
	if err != nil {
		return fmt.Errorf("msdb.dbo.MSdistributiondbs: %w", err)
	}
	d.MinRetentionHours = model.Ptr(minRetention)
	d.MaxRetentionHours = model.Ptr(maxRetention)
	d.HistoryRetentionHours = model.Ptr(historyRetention)
	d.DeleteBatchSizeXact = model.Ptr(deleteXact)
	d.DeleteBatchSizeCmd = model.Ptr(deleteCmd)
	d.AdminPasswordSecret = model.Ptr(e.secret("distributor.admin_password_secret",
		"SQL", d.Server, "distributor_admin"))
	if err := e.readDistributionFiles(d); err != nil {
		return err
	}
	if err := e.readDistributorLink(d); err != nil {
		return err
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

	if err := e.probeReplServers(e.dist); err != nil {
		return err
	}
	if e.replServers {
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

// probeReplServers decides, once, whether the distribution database dist
// (quoted) has MSreplservers, by reading it.
func (e *exporter) probeReplServers(dist string) error {
	if e.replProbed {
		return nil
	}
	_, err := e.src.Distributor.ExecContext(e.ctx, strings.ReplaceAll(qReplServersProbe, "{dist}", dist))
	if e.replServers, err = replServersExist(err); err != nil {
		return err
	}
	e.replProbed = true
	return nil
}

// replServersExist reads the result of qReplServersProbe: no error means the
// table exists, error 208 that it does not (a distributor older than 2016 SP2
// CU3 or 2017 CU6), and any other error, 229 for a login denied the table, is
// an error. Neither OBJECT_ID, NULL for a table the login cannot see, nor the
// version, 12.0.2000.8 on a Managed Instance with the current engine, can
// decide it.
func replServersExist(err error) (bool, error) {
	switch {
	case err == nil:
		return true, nil
	case errorNumber(err) == 208:
		return false, nil
	}
	return false, fmt.Errorf("MSreplservers: %w", err)
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
func (e *exporter) profileName(path string, id int) string {
	if id == 0 {
		return ""
	}
	p, ok := e.profiles[id]
	if !ok {
		e.find(model.FindingIncomplete, path, "agent profile id %d not found in msdb.dbo.MSagent_profiles", id)
		return ""
	}
	e.usedProfiles[id] = true
	return p.name
}

// collectProfiles exports every user-defined profile of the distributor.
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

	e.cfg.AgentProfiles = selectProfiles(e.profiles, params)
	return nil
}

// profileParameters is a profile's parameters as read, an empty non-nil map
// when it has none: nil would mean the template's set (model.ProfileParameters).
func profileParameters(m map[string]string) model.ProfileParameters {
	if m == nil {
		return model.ProfileParameters{}
	}
	return m
}

// selectProfiles returns every user-defined profile of an in-scope agent
// type, whether or not an agent uses it, sorted by agent type then name,
// and an empty non-nil list when there is none.
func selectProfiles(profiles map[int]profileRow, params map[int]map[string]string) model.AgentProfiles {
	type entry struct {
		code int
		name string
		prof model.AgentProfile
	}
	var es []entry
	for id, p := range profiles {
		if !p.userDefined || !inScopeAgentType(p.agentType) {
			continue
		}
		es = append(es, entry{p.agentType, p.name, model.AgentProfile{
			Name:        p.name,
			AgentType:   decode.AgentType(p.agentType),
			Description: model.Ptr(p.description),
			Default:     model.Ptr(p.isDefault),
			Parameters:  profileParameters(params[id]),
		}})
	}
	sort.Slice(es, func(i, j int) bool {
		if es[i].code != es[j].code {
			return es[i].code < es[j].code
		}
		return es[i].name < es[j].name
	})
	// Non-nil even when empty: the profiles were read, so the export
	// manages them and writes agent_profiles: [] (model.AgentProfiles).
	out := model.AgentProfiles{}
	for _, e := range es {
		out = append(out, e.prof)
	}
	return out
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

var passwordArg = regexp.MustCompile(`(?is)([-/]\w*password\s+).*$`)

// maskPasswords hides everything from the value of the first -*Password (or
// /*Password) switch to the end of the line. The server writes the password
// raw, so its extent is unknown when it holds spaces, quotes or brackets; the
// command is shown, never compared, so losing what follows is acceptable and
// leaking is not.
func maskPasswords(cmd string) string {
	return passwordArg.ReplaceAllString(cmd, "${1}********")
}

// quoteName quotes an identifier the way QUOTENAME does.
func quoteName(s string) string {
	return "[" + strings.ReplaceAll(s, "]", "]]") + "]"
}

// readSyncWithBackup reads the sync with backup option of the publication
// database.
func (e *exporter) readSyncWithBackup() error {
	var v sql.NullInt64
	if err := e.src.Publisher.QueryRowContext(e.ctx, qSyncWithBackup, e.src.Database).Scan(&v); err != nil {
		return err
	}
	if !v.Valid {
		e.find(model.FindingUnreadable, "publisher.sync_with_backup", "DATABASEPROPERTYEX returned NULL for IsSyncWithBackup")
		return nil
	}
	e.cfg.Publisher.SyncWithBackup = model.Ptr(v.Int64 != 0)
	return nil
}

// readDistributionFiles reads the folders and names of the first data and log
// files of the distribution database.
func (e *exporter) readDistributionFiles(d *model.Distributor) error {
	rows, err := e.src.Distributor.QueryContext(e.ctx, qDistributionFiles, d.Database)
	if err != nil {
		return fmt.Errorf("sys.master_files: %w", err)
	}
	defer rows.Close()
	var haveData, haveLog bool
	for rows.Next() {
		var typ int
		var path string
		if err := rows.Scan(&typ, &path); err != nil {
			return err
		}
		folder, file := splitFilePath(path)
		switch {
		case typ == 0 && !haveData:
			haveData = true
			d.DataFolder, d.DataFile = model.Ptr(folder), model.Ptr(file)
		case typ == 1 && !haveLog:
			haveLog = true
			d.LogFolder, d.LogFile = model.Ptr(folder), model.Ptr(file)
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if !haveData {
		for _, k := range []string{"data_folder", "data_file"} {
			e.find(model.FindingUnreadable, "distributor."+k, "no data file of %s in sys.master_files", d.Database)
		}
	}
	if !haveLog {
		for _, k := range []string{"log_folder", "log_file"} {
			e.find(model.FindingUnreadable, "distributor."+k, "no log file of %s in sys.master_files", d.Database)
		}
	}
	return nil
}

// splitFilePath cuts a physical file name at its last / or \.
func splitFilePath(p string) (folder, file string) {
	i := strings.LastIndexAny(p, `/\`)
	if i < 0 {
		return "", p
	}
	return p[:i], p[i+1:]
}

// readDistributorLink reads, at the publisher, the repl_distributor linked
// server: how the publisher connects to the distributor, and the multi subnet
// failover option.
func (e *exporter) readDistributorLink(d *model.Distributor) error {
	rows, err := e.src.Publisher.QueryContext(e.ctx, qDistributorLink)
	if err != nil {
		return fmt.Errorf("sys.servers: %w", err)
	}
	defer rows.Close()
	var found bool
	var provider, remote sql.NullString
	var self sql.NullInt64
	var canSee int
	for rows.Next() {
		if found {
			continue // sys.servers names are unique: one row at most
		}
		found = true
		if err := rows.Scan(&provider, &self, &remote, &canSee); err != nil {
			return err
		}
	}
	if err := rows.Err(); err != nil {
		return err
	}
	if !found {
		e.find(model.FindingUnreadable, "distributor.admin_link_security", "linked server repl_distributor not found at the publisher")
		e.find(model.FindingUnreadable, "distributor.multi_subnet_failover", "linked server repl_distributor not found at the publisher")
		return nil
	}
	for _, f := range linkSettings(d, canSee == 1, provider, self, remote) {
		e.find(f.Kind, f.Path, "%s", f.Message)
	}
	return nil
}

// linkSettings sets the distributor properties read from the repl_distributor
// linked server and returns the findings of those it cannot read. Without
// ALTER ANY LINKED SERVER (canSee false) the provider string reads NULL
// whatever it holds, so multi_subnet_failover and the link_* keys are
// unreadable, not absent; the login mapping is hidden too.
func linkSettings(d *model.Distributor, canSee bool, provider sql.NullString, self sql.NullInt64, remote sql.NullString) []model.Finding {
	var out []model.Finding
	if canSee {
		d.MultiSubnetFailover = model.Ptr(multiSubnetFailover(provider))
		d.LinkEncrypt, d.LinkTrustServerCertificate, d.LinkHostNameInCertificate = distributorLinkEncryption(provider)
	} else {
		for _, k := range []string{"multi_subnet_failover", "link_encrypt", "link_trust_server_certificate", "link_host_name_in_certificate"} {
			out = append(out, model.Finding{Kind: model.FindingUnreadable, Path: "distributor." + k,
				Message: "the provider string of repl_distributor is NULL to a login without ALTER ANY LINKED SERVER"})
		}
	}
	switch {
	case self.Valid && self.Int64 == 1:
		d.AdminLinkSecurity = model.Ptr("windows")
	case self.Valid && self.Int64 == 0 && strings.EqualFold(remote.String, "distributor_admin"):
		d.AdminLinkSecurity = model.Ptr("sql")
	case !canSee:
		out = append(out, model.Finding{Kind: model.FindingUnreadable, Path: "distributor.admin_link_security",
			Message: "the login mappings of repl_distributor (sys.linked_logins) are not visible to the login, which has neither ALTER ANY LINKED SERVER nor VIEW ANY DEFINITION"})
	default:
		out = append(out, model.Finding{Kind: model.FindingUnreadable, Path: "distributor.admin_link_security",
			Message: "the login mapping of repl_distributor is neither the current security context nor distributor_admin"})
	}
	return out
}

// providerStringValue returns the value of key in a provider string, a list
// of key=value pairs separated by ";", matching the key in any case; nil when
// the key is absent.
func providerStringValue(provider sql.NullString, key string) *string {
	if !provider.Valid {
		return nil
	}
	for _, pair := range strings.Split(provider.String, ";") {
		k, v, ok := strings.Cut(pair, "=")
		if ok && strings.EqualFold(strings.TrimSpace(k), key) {
			return model.Ptr(strings.TrimSpace(v))
		}
	}
	return nil
}

// distributorLinkEncryption reads the encryption settings that SQL Server
// 2025 writes in the provider string of repl_distributor for the
// sp_adddistributor parameters @encrypt_distributor_connection,
// @trust_distributor_certificate and @host_name_in_distributor_certificate.
// The keys are those sp_changedistributor_property matches, in any case:
// Encrypt, TrustServerCertificate and HostNameInCertificate. Each is nil when
// absent: the parameter was not passed, or the instance is older than 2025.
func distributorLinkEncryption(provider sql.NullString) (encrypt, trust, hostName *string) {
	return providerStringValue(provider, "Encrypt"),
		providerStringValue(provider, "TrustServerCertificate"),
		providerStringValue(provider, "HostNameInCertificate")
}

// multiSubnetFailover tells whether the provider string of the
// repl_distributor linked server holds MultiSubnetFailover=Yes. The string is
// a list of key=value pairs separated by ";" that also holds addr=... and, on
// SQL Server 2025, the encryption settings.
func multiSubnetFailover(provider sql.NullString) bool {
	if !provider.Valid {
		return false
	}
	for _, pair := range strings.Split(provider.String, ";") {
		k, v, ok := strings.Cut(pair, "=")
		if ok && strings.EqualFold(strings.TrimSpace(k), "MultiSubnetFailover") &&
			strings.EqualFold(strings.TrimSpace(v), "Yes") {
			return true
		}
	}
	return false
}
