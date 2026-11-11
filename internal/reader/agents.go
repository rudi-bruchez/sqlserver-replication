package reader

import (
	"database/sql"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"

	mssql "github.com/microsoft/go-mssqldb"

	"github.com/rudi-bruchez/sqlserver-replication/internal/decode"
	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
)

// agentRow holds the columns shared by the three MS*_agents tables.
type agentRow struct {
	securityMode int
	login        string
	profileID    int
	jobID        string
	stepUID      string
	jobLogin     string
	// snapshot is set for a snapshot agent, whose command line carries the
	// distributor connection.
	snapshot bool
	// jobs is the connection whose msdb holds the agent's job; nil is the
	// distributor.
	jobs *sql.DB
	// pullSubscriber is set, to the subscriber name, for a pull agent: its
	// connection to the subscriber is read from the switches of the job step,
	// and its job login is the credential of the step's proxy, both with
	// run_as (MSsubscription_properties.job_login only stores @cl_login).
	pullSubscriber string
}

// agent builds the model of an agent: profile, job, run-as account, command
// line and schedules. path is the path of the agent, and secretParts the
// parts of the name of its password secret when it uses SQL Server
// authentication.
func (e *exporter) agent(path, label string, r agentRow, secretParts ...string) (model.Agent, error) {
	a := model.Agent{Profile: model.Ptr(e.profileName(model.Join(path, "profile"), r.profileID))}
	pull := r.pullSubscriber != ""
	if !pull {
		a.Connection = &model.Connection{Security: model.Ptr(decode.SecurityMode(r.securityMode)), Login: model.Ptr(r.login)}
		if r.securityMode == 0 {
			a.Connection.PasswordSecret = model.Ptr(e.secret(model.Join(model.Join(path, "connection"), "password_secret"),
				"SQL", append(secretParts, r.login)...))
		}
		e.jobLogin(path, &a, r.jobLogin)
	}
	jobs := r.jobs
	if jobs == nil {
		jobs = e.src.Distributor
	}

	if r.jobID == "" {
		e.find(model.FindingIncomplete, path, "%s: no SQL Server Agent job recorded", label)
		return a, nil
	}
	var jobName, command string
	var enabled, stepFound int
	var proxyID sql.NullInt32
	var proxyFound int
	var credential sql.NullString
	err := jobs.QueryRowContext(e.ctx, qJob, r.jobID, r.stepUID).Scan(
		&jobName, &enabled, &proxyID, &proxyFound, &credential, &command, &stepFound)
	if err == sql.ErrNoRows {
		e.find(model.FindingIncomplete, path, "%s: job %s recorded by replication no longer exists in msdb", label, r.jobID)
		return a, nil
	}
	if err != nil {
		return a, err
	}
	a.JobName = model.Ptr(jobName)
	a.JobEnabled = model.Ptr(enabled != 0)
	if stepFound == 0 {
		// Without a step, run_as and command were not read: they stay nil,
		// since "" for run_as would claim the Agent service account.
		e.find(model.FindingIncomplete, path, "%s: job %s has no replication step; command and run-as account not exported", label, jobName)
	} else {
		if ra, ok := runAs(proxyID, proxyFound != 0, credential); ok {
			a.RunAs = ra
			if pull {
				e.jobLogin(path, &a, *ra)
			}
		} else {
			// "" would claim the Agent service account: run_as stays nil.
			e.find(model.FindingUnreadable, model.Join(path, "run_as"),
				"the job step runs under proxy %d, whose credential this login cannot see", proxyID.Int32)
			if pull {
				e.find(model.FindingUnreadable, model.Join(path, "job_login"),
					"the job step runs under proxy %d, whose credential this login cannot see", proxyID.Int32)
			}
		}
		a.Command = model.Ptr(maskPasswords(strings.TrimSpace(command)))
		if r.snapshot {
			e.distributorConnection(path, &a, command)
		}
		if pull {
			a.Connection = e.commandConnection(model.Join(path, "connection"), command, "Subscriber", r.pullSubscriber)
		}
	}

	rows, err := jobs.QueryContext(e.ctx, qJobSchedules, r.jobID)
	if err != nil {
		return a, err
	}
	defer rows.Close()
	// The job was read: no schedule is an empty list, not an omitted one.
	schedules := []model.Schedule{}
	a.Schedules = &schedules
	for rows.Next() {
		var s model.Schedule
		var enabled, freqType, subdayType int
		if err := rows.Scan(&s.Name, &enabled, &freqType, &s.Interval, &subdayType, &s.SubdayInterval,
			&s.RelativeInterval, &s.RecurrenceFactor, &s.StartDate, &s.EndDate, &s.StartTime, &s.EndTime); err != nil {
			return a, err
		}
		s.Enabled = enabled != 0
		s.Frequency = decode.FreqType(freqType)
		// Agent start and idle schedules carry no interval of their own, and
		// one-time schedules usually store freq_subday_type 0, which has no
		// meaning.
		if freqType != 64 && freqType != 128 {
			if subdayType != 0 {
				s.Subday = decode.FreqSubdayType(subdayType)
			}
		} else {
			s.Interval, s.SubdayInterval, s.RelativeInterval, s.RecurrenceFactor = 0, 0, 0, 0
		}
		schedules = append(schedules, s)
	}
	return a, rows.Err()
}

// jobLogin sets the job login of an agent and, when it is not empty, the
// name of its password secret.
func (e *exporter) jobLogin(path string, a *model.Agent, login string) {
	a.JobLogin = model.Ptr(login)
	if login != "" {
		a.JobPasswordSecret = model.Ptr(e.secret(model.Join(path, "job_password_secret"), "WIN", login))
	}
}

// runAs gives the account of a job step: "" when it has no proxy (the Agent
// service account), nil and false when the proxy or its credential cannot be
// seen, otherwise the credential identity.
func runAs(proxyID sql.NullInt32, proxyFound bool, credential sql.NullString) (*string, bool) {
	if !proxyID.Valid {
		return model.Ptr(""), true
	}
	if !proxyFound || !credential.Valid {
		return nil, false
	}
	return model.Ptr(credential.String), true
}

// distributorConnection reads the connection of a snapshot agent to the
// distributor from the switches of its command line (commandConnection).
func (e *exporter) distributorConnection(path string, a *model.Agent, command string) {
	distributor := ""
	if e.cfg.Distributor != nil {
		distributor = e.cfg.Distributor.Server
	}
	a.DistributorConnection = e.commandConnection(model.Join(path, "distributor_connection"), command, "Distributor", distributor)
}

// commandConnection reads the connection an agent makes to side (Distributor
// or Subscriber) from the -<side>, -<side>SecurityMode and -<side>Login
// switches of its command line; server names the password secret. An absent
// security mode is 1, Windows authentication. Whatever cannot be read gives a
// nil connection (or a nil login) with an unreadable finding at cpath: never
// a default and never a secret name built from a guess.
func (e *exporter) commandConnection(cpath, command, side, server string) *model.Connection {
	unreadable := func(p, format string, args ...any) {
		e.find(model.FindingUnreadable, p, format, args...)
	}
	// A switch name glued to the text before it is not a switch the server
	// wrote: reading around it could default a SQL connection to Windows.
	for _, name := range []string{side, side + "SecurityMode", side + "Login"} {
		if gluedSwitch(command, name) {
			unreadable(cpath, "-%s is not preceded by whitespace in the command line", name)
			return nil
		}
	}
	// -<side> is bracketed by the server: an unbalanced bracket or quote
	// means the line is not what the server wrote.
	if _, present, balanced := bracketedSwitch(command, side); present && !balanced {
		unreadable(cpath, "the command line has an unbalanced bracket or quote after -%s", side)
		return nil
	}
	mode := 1
	if rest, present := switchStart(command, side+"SecurityMode"); present {
		// The value is the first token: the step can carry other switches
		// after it (-OutputVerboseLevel 2).
		v := rest
		if i := strings.IndexAny(rest, " \t\r\n"); i >= 0 {
			v = rest[:i]
		}
		n, err := strconv.Atoi(v)
		if err != nil {
			unreadable(cpath, "-%sSecurityMode %q is not a number", side, v)
			return nil
		}
		mode = n
	}
	c := &model.Connection{Security: model.Ptr(decode.SecurityMode(mode))}
	if mode != 0 {
		return c
	}
	login, ok := sideLoginSwitch(command, side)
	if !ok {
		unreadable(model.Join(cpath, "login"), "the -%sLogin value of the command line cannot be told from the other switches", side)
		return c
	}
	c.Login = model.Ptr(login)
	c.PasswordSecret = model.Ptr(e.secret(model.Join(cpath, "password_secret"), "SQL", server, login))
	return c
}

var otherSwitch = regexp.MustCompile(`\s[-/][A-Za-z]`)

// loginSwitch reads -DistributorLogin, which the server writes raw, as
// " -DistributorLogin <login> -DistributorPassword <password>" (measured): the
// login is the text up to the following password switch. ok is false when the
// switch is absent or empty, no password switch follows, the span holds
// another switch-like token, or the value contains "password": the login
// cannot then be told from the rest of the line. The first occurrence of a
// repeated switch is kept; which one the agent honours is not measured.
func loginSwitch(cmd string) (login string, ok bool) {
	return sideLoginSwitch(cmd, "Distributor")
}

// sideLoginSwitch is loginSwitch for -<side>Login, ended by -<side>Password.
// For a pull agent's -SubscriberLogin the layout is assumed, not measured:
// sp_addpullsubscription_agent ignores its deprecated subscriber security
// parameters and writes -SubscriberSecurityMode 1 even when given 0 (lab,
// SQL Server 2022 CU27), so only an edited step holds the switch.
func sideLoginSwitch(cmd, side string) (login string, ok bool) {
	rest, present := switchStart(cmd, side+"Login")
	if !present {
		return "", false
	}
	loginEnd := regexp.MustCompile(`(?i)\s[-/]` + regexp.QuoteMeta(side) + `Password(?:\s|$)`)
	loc := loginEnd.FindStringIndex(" " + rest)
	if loc == nil {
		return "", false
	}
	span := rest[:loc[0]]
	login = strings.TrimSpace(span)
	if login == "" || otherSwitch.MatchString(" "+span) || strings.Contains(strings.ToLower(login), "password") {
		return "", false
	}
	return login, true
}

// gluedSwitch reports whether -name occurs as a whole word that is not at the
// start of the line or preceded by whitespace.
func gluedSwitch(cmd, name string) bool {
	re := regexp.MustCompile(`(?i)-` + regexp.QuoteMeta(name) + `(?:\s|$)`)
	for _, loc := range re.FindAllStringIndex(cmd, -1) {
		if loc[0] > 0 && !strings.ContainsRune(" \t\r\n", rune(cmd[loc[0]-1])) {
			return true
		}
	}
	return false
}

// switchStart returns what follows the first occurrence of -name as a whole
// word preceded by whitespace or the start of the line, and whether it was
// found. The first occurrence is kept when a switch is repeated; which one
// the agent honours is not measured.
func switchStart(cmd, name string) (string, bool) {
	re := regexp.MustCompile(`(?i)(?:^|\s)-` + regexp.QuoteMeta(name) + `(?:\s|$)`)
	loc := re.FindStringIndex(cmd)
	if loc == nil {
		return "", false
	}
	return strings.TrimLeft(cmd[loc[1]:], " \t\r\n"), true
}

// bracketedSwitch returns the value of a switch the server writes in brackets
// (or quotes) with one level of [...] (]] undoubled) or "..." removed.
// balanced is false when a bracket or quote is not closed.
func bracketedSwitch(cmd, name string) (value string, present, balanced bool) {
	rest, ok := switchStart(cmd, name)
	if !ok {
		return "", false, true
	}
	if rest == "" {
		return "", true, true
	}
	var end rune
	switch rest[0] {
	case '[':
		end = ']'
	case '"':
		end = '"'
	default:
		if i := strings.IndexAny(rest, " \t\r\n"); i >= 0 {
			rest = rest[:i]
		}
		return rest, true, true
	}
	r := []rune(rest)
	for i := 1; i < len(r); i++ {
		if r[i] != end {
			continue
		}
		if end == ']' && i+1 < len(r) && r[i+1] == ']' {
			i++
			continue
		}
		inner := string(r[1:i])
		if end == ']' {
			inner = strings.ReplaceAll(inner, "]]", "]")
		}
		return inner, true, true
	}
	return "", true, false
}

// commandSwitch returns the value of -name with one level of [...] or "..."
// removed, matching the switch case-insensitively as a whole word. ok is
// false when the switch is absent, has no value or has an unbalanced bracket
// or quote.
func commandSwitch(cmd, name string) (string, bool) {
	v, present, balanced := bracketedSwitch(cmd, name)
	if !present || !balanced || v == "" {
		return "", false
	}
	return v, true
}

func (e *exporter) readLogReaderAgent() error {
	var name string
	var r agentRow
	err := e.src.Distributor.QueryRowContext(e.ctx, e.distQuery(qLogReaderAgent), e.publisherID, e.src.Database).Scan(
		&name, &r.securityMode, &r.login, &r.profileID, &r.jobID, &r.stepUID, &r.jobLogin)
	if err == sql.ErrNoRows {
		if len(e.cfg.Publications) > 0 {
			e.find(model.FindingIncomplete, "publisher.log_reader_agent", "no log reader agent found for %s.%s", e.cfg.Publisher.Server, e.src.Database)
		}
		return nil
	}
	if err != nil {
		return err
	}
	a, err := e.agent("publisher.log_reader_agent", "log reader agent "+name, r, e.cfg.Publisher.Server)
	if err != nil {
		return err
	}
	e.cfg.Publisher.LogReaderAgent = &a
	return nil
}

func (e *exporter) readSnapshotAgents() error {
	rows, err := e.src.Distributor.QueryContext(e.ctx, e.distQuery(qSnapshotAgents), e.publisherID, e.src.Database)
	if err != nil {
		return err
	}
	type found struct {
		publication string
		row         agentRow
	}
	var all []found
	for rows.Next() {
		var f found
		if err := rows.Scan(&f.publication, &f.row.securityMode, &f.row.login, &f.row.profileID,
			&f.row.jobID, &f.row.stepUID, &f.row.jobLogin); err != nil {
			rows.Close()
			return err
		}
		f.row.snapshot = true
		all = append(all, f)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	// The job queries reuse the connection pool, so the agent rows are read
	// in full before the jobs are looked up.
	for _, f := range all {
		p := e.publicationByName(f.publication)
		if p == nil {
			continue
		}
		a, err := e.agent(model.Join(publicationPath(p.Name), "snapshot_agent"), "snapshot agent of "+p.Name, f.row, e.cfg.Publisher.Server)
		if err != nil {
			return err
		}
		p.SnapshotAgent = &a
	}
	for _, p := range e.cfg.Publications {
		if p.SnapshotAgent == nil {
			e.find(model.FindingIncomplete, model.Join(publicationPath(p.Name), "snapshot_agent"), "publication %s: no snapshot agent found at the distributor", p.Name)
		}
	}
	return nil
}

func (e *exporter) readDistributionAgents() error {
	rows, err := e.src.Distributor.QueryContext(e.ctx, e.distQuery(qDistributionAgents), e.publisherID, e.src.Database)
	if err != nil {
		return err
	}
	type found struct {
		publication, subscriber, database string
		subscriptionType                  int
		streams, memoryOptimized          int
		row                               agentRow
	}
	var all []found
	for rows.Next() {
		var f found
		if err := rows.Scan(&f.publication, &f.subscriber, &f.database, &f.subscriptionType,
			&f.row.securityMode, &f.row.login, &f.row.profileID, &f.row.jobID, &f.row.stepUID,
			&f.streams, &f.memoryOptimized, &f.row.jobLogin); err != nil {
			rows.Close()
			return err
		}
		all = append(all, f)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	// Server and database names are compared case-insensitively, as the
	// replication procedures do; publication names are compared exactly.
	find := func(subscriptionType int, publication, subscriber, database string) *found {
		for k := range all {
			f := &all[k]
			if f.subscriptionType == subscriptionType && f.publication == publication &&
				strings.EqualFold(f.subscriber, subscriber) && strings.EqualFold(f.database, database) {
				return f
			}
		}
		return nil
	}
	build := func(path, label string, f *found, subscriber string) (model.DistributionAgent, error) {
		a, err := e.agent(path, label, f.row, subscriber)
		return model.DistributionAgent{
			Agent:               a,
			SubscriptionStreams: model.Ptr(f.streams),
			MemoryOptimized:     model.Ptr(f.memoryOptimized != 0),
		}, err
	}

	// The distributor keeps a row for a pull agent too, with its profile.
	// A shared pull agent is recorded with publication = N'ALL' and
	// subscription_type 1, as a shared push agent is with 0 (measured by two
	// reviewers on the lab, SQL Server 2022 CU27).
	distRow := func(publication, subscriber, database string) *pullDistRow {
		f := find(1, publication, subscriber, database)
		if f == nil {
			return nil
		}
		return &pullDistRow{profileID: f.row.profileID, streams: f.streams, memoryOptimized: f.memoryOptimized != 0}
	}
	type sharedPull struct {
		subscriber, database, path string
		built, unreadable          bool
	}
	var sharedPulls []*sharedPull
	sharedPullIndex := map[[2]string]*sharedPull{}
	pull := func(p *model.Publication, s *model.Subscription, label string) error {
		subPath := subscriptionPath(p.Name, s.Subscriber, s.Database)
		if *p.IndependentAgent {
			path := model.Join(subPath, "pull_agent")
			r, db, err := e.readPullRow(p, s, label, path, path)
			if err != nil || r == nil {
				return err
			}
			s.PullAgent, err = e.buildPullAgent(path, "pull agent of "+label, r, distRow(p.Name, s.Subscriber, s.Database), db, s.Subscriber)
			return err
		}
		// One pull agent serves every subscription of the subscriber
		// database to a publication without an independent agent (one job,
		// the same agent_id and job_step_uid in every row): each row is
		// checked, the agent is exported once.
		key := [2]string{strings.ToUpper(s.Subscriber), strings.ToUpper(s.Database)}
		sp := sharedPullIndex[key]
		if sp == nil {
			sp = &sharedPull{subscriber: s.Subscriber, database: s.Database,
				path: model.Join("publisher", "shared_pull_agents") +
					model.Element(model.SharedPullAgent{Subscriber: s.Subscriber, Database: s.Database}.Key())}
			sharedPullIndex[key] = sp
			sharedPulls = append(sharedPulls, sp)
		}
		r, db, err := e.readPullRow(p, s, label, sp.path, subPath)
		if err != nil {
			return err
		}
		if db == nil {
			sp.unreadable = true
		}
		if r == nil || sp.built {
			return nil
		}
		a, err := e.buildPullAgent(sp.path, fmt.Sprintf("shared pull agent of %s.%s", sp.subscriber, sp.database), r,
			distRow("ALL", s.Subscriber, s.Database), db, s.Subscriber)
		if err != nil {
			return err
		}
		sp.built = true
		e.cfg.Publisher.SharedPullAgents = append(e.cfg.Publisher.SharedPullAgents,
			model.SharedPullAgent{Subscriber: sp.subscriber, Database: sp.database, PullAgent: *a})
		return nil
	}

	// A shared agent serves every non-independent publication of the
	// database for one subscriber database: it is exported once.
	shared := map[[2]string]bool{}
	for i := range e.cfg.Publications {
		p := &e.cfg.Publications[i]
		for j := range p.Subscriptions {
			s := &p.Subscriptions[j]
			label := fmt.Sprintf("publication %s, subscription %s.%s", p.Name, s.Subscriber, s.Database)
			if s.Type != nil && *s.Type == "pull" {
				if err := pull(p, s, label); err != nil {
					return err
				}
				continue
			}
			if *p.IndependentAgent {
				path := model.Join(subscriptionPath(p.Name, s.Subscriber, s.Database), "distribution_agent")
				f := find(0, p.Name, s.Subscriber, s.Database)
				if f == nil {
					e.find(model.FindingIncomplete, path, "%s: no push distribution agent found at the distributor", label)
					continue
				}
				a, err := build(path, "distribution agent of "+label, f, s.Subscriber)
				if err != nil {
					return err
				}
				s.DistributionAgent = &a
				continue
			}
			key := [2]string{strings.ToUpper(s.Subscriber), strings.ToUpper(s.Database)}
			if shared[key] {
				continue
			}
			shared[key] = true
			path := model.Join("publisher", "shared_distribution_agents") +
				model.Element(model.SharedDistributionAgent{Subscriber: s.Subscriber, Database: s.Database}.Key())
			f := find(0, "ALL", s.Subscriber, s.Database)
			if f == nil {
				e.find(model.FindingIncomplete, path, "subscriber %s.%s: no shared push distribution agent found at the distributor", s.Subscriber, s.Database)
				continue
			}
			a, err := build(model.Join(path, "distribution_agent"), fmt.Sprintf("shared distribution agent of %s.%s", s.Subscriber, s.Database), f, s.Subscriber)
			if err != nil {
				return err
			}
			e.cfg.Publisher.SharedDistributionAgents = append(e.cfg.Publisher.SharedDistributionAgents,
				model.SharedDistributionAgent{Subscriber: s.Subscriber, Database: s.Database, DistributionAgent: a})
		}
	}
	for _, sp := range sharedPulls {
		if !sp.built && !sp.unreadable {
			e.find(model.FindingIncomplete, sp.path, "subscriber %s.%s: no shared pull agent found at the subscriber", sp.subscriber, sp.database)
		}
	}
	sort.Slice(e.cfg.Publisher.SharedPullAgents, func(i, j int) bool {
		a, b := e.cfg.Publisher.SharedPullAgents[i], e.cfg.Publisher.SharedPullAgents[j]
		if a.Subscriber != b.Subscriber {
			return a.Subscriber < b.Subscriber
		}
		return a.Database < b.Database
	})
	sort.Slice(e.cfg.Publisher.SharedDistributionAgents, func(i, j int) bool {
		a, b := e.cfg.Publisher.SharedDistributionAgents[i], e.cfg.Publisher.SharedDistributionAgents[j]
		if a.Subscriber != b.Subscriber {
			return a.Subscriber < b.Subscriber
		}
		return a.Database < b.Database
	})
	return nil
}

// pullDistRow is what the distributor records about a pull agent
// (MSdistribution_agents, subscription_type 1).
type pullDistRow struct {
	profileID       int
	streams         int
	memoryOptimized bool
}

// pullRow is one row of qPullSubscription.
type pullRow struct {
	subscriptionType           int
	independent, immediate     int
	description, agentID       string
	hasProperties              int
	distributor                string
	distributorSecurity        int
	distributorLogin           string
	altSnapshotFolder, workDir string
	useFTP, syncmgr            int
	stepUID, dtsPackage        string
}

// readPullRow reads the row of a pull subscription at its subscriber:
// MSreplication_subscriptions and MSsubscription_properties in the
// subscription database. agentPath is the path of the agent, where a
// subscriber that cannot be read is reported, and rowPath the path where
// what is wrong with this subscription's row is reported. It returns the row
// and the subscriber connection, the row nil when there is none to export,
// the connection nil when the subscriber or its database cannot be read.
func (e *exporter) readPullRow(p *model.Publication, s *model.Subscription, label, agentPath, rowPath string) (*pullRow, *sql.DB, error) {
	subPath := subscriptionPath(p.Name, s.Subscriber, s.Database)
	db := subscriberConn(e.src.Subscribers, s.Subscriber)
	if db == nil {
		e.find(model.FindingUnreadable, agentPath, "subscriber %s is not connected: pass -server %s=ADDRESS", s.Subscriber, s.Subscriber)
		return nil, nil, nil
	}
	var exists int
	if err := db.QueryRowContext(e.ctx, qDatabaseExists, s.Database).Scan(&exists); err != nil {
		return nil, nil, fmt.Errorf("subscriber %s: %w", s.Subscriber, err)
	}
	if exists == 0 {
		e.find(model.FindingIncomplete, agentPath, "subscription database %s does not exist at subscriber %s", s.Database, s.Subscriber)
		return nil, nil, nil
	}

	var pull *pullRow
	anonymous := false
	err := func() error {
		rows, err := db.QueryContext(e.ctx, subscriberQuery(s.Database), e.cfg.Publisher.Server, e.src.Database, p.Name)
		if err != nil {
			return err
		}
		defer rows.Close()
		for rows.Next() {
			var r pullRow
			if err := rows.Scan(&r.subscriptionType, &r.independent, &r.immediate, &r.description, &r.agentID,
				&r.hasProperties, &r.distributor, &r.distributorSecurity, &r.distributorLogin,
				&r.altSnapshotFolder, &r.workDir, &r.useFTP, &r.syncmgr, &r.stepUID, &r.dtsPackage); err != nil {
				return err
			}
			switch r.subscriptionType {
			case 1:
				pull = &r
			case 2:
				anonymous = true
			}
		}
		return rows.Err()
	}()
	if err != nil {
		// The tables are checked by the query itself: OBJECT_ID says
		// nothing of a table that metadata visibility hides.
		if errorNumber(err) == 208 {
			e.find(model.FindingIncomplete, agentPath, "no table MSreplication_subscriptions or MSsubscription_properties in database %s at subscriber %s", s.Database, s.Subscriber)
			return nil, nil, nil
		}
		return nil, nil, fmt.Errorf("subscriber %s: %w", s.Subscriber, err)
	}
	// The job queries reuse the connection pool: the rows are read in full
	// first.
	switch {
	case anonymous && pull == nil:
		e.find(model.FindingOutOfScope, subPath, "%s: the subscriber holds the subscription as anonymous (subscription_type 2), out of scope: the subscription is exported, its pull agent is not", label)
	case anonymous:
		e.find(model.FindingOutOfScope, subPath, "%s: the subscriber also holds an anonymous row (subscription_type 2) for the publication, out of scope and not exported", label)
	}
	if pull == nil {
		if !anonymous {
			e.find(model.FindingIncomplete, rowPath, "%s: no pull subscription row in %s.dbo.MSreplication_subscriptions at subscriber %s", label, s.Database, s.Subscriber)
		}
		return nil, db, nil
	}
	// independent_agent and immediate_sync are parameters of
	// sp_addpullsubscription that default to 1, not copies of the
	// publication's: the model keeps the publication's values.
	if (pull.independent != 0) != *p.IndependentAgent || (pull.immediate != 0) != *p.ImmediateSync {
		e.find(model.FindingIncomplete, rowPath, "%s: the subscriber records independent_agent %d and immediate_sync %d, the publication %t and %t",
			label, pull.independent, pull.immediate, *p.IndependentAgent, *p.ImmediateSync)
	}
	if pull.dtsPackage != "" {
		e.find(model.FindingOutOfScope, rowPath, "%s: DTS package %s, out of scope", label, pull.dtsPackage)
	}
	return pull, db, nil
}

// errorNumber returns the SQL Server error number of err, 0 when it is not
// a server error.
func errorNumber(err error) int32 {
	var me mssql.Error
	if errors.As(err, &me) {
		return me.Number
	}
	return 0
}

// buildPullAgent builds a pull agent from its row at the subscriber, its job
// in the subscriber's msdb (db) and its row at the distributor (d, nil when
// there is none).
func (e *exporter) buildPullAgent(path, label string, pull *pullRow, d *pullDistRow, db *sql.DB, subscriber string) (*model.PullAgent, error) {
	row := agentRow{jobID: pull.agentID, stepUID: pull.stepUID, jobs: db, pullSubscriber: subscriber}
	if d != nil {
		row.profileID = d.profileID
	}
	a, err := e.agent(path, label, row)
	if err != nil {
		return nil, err
	}
	pa := &model.PullAgent{
		DistributionAgent: model.DistributionAgent{Agent: a},
		Description:       model.Ptr(pull.description),
	}
	if d != nil {
		pa.SubscriptionStreams = model.Ptr(d.streams)
		pa.MemoryOptimized = model.Ptr(d.memoryOptimized)
	} else {
		// No row: the profile is unknown, not the default.
		pa.Profile = nil
		e.find(model.FindingIncomplete, path, "%s: no pull distribution agent found at the distributor", label)
	}
	if pull.hasProperties == 0 {
		e.find(model.FindingIncomplete, path, "%s: no row in MSsubscription_properties at subscriber %s", label, subscriber)
		return pa, nil
	}
	pa.Distributor = model.Ptr(pull.distributor)
	pa.AltSnapshotFolder = model.Ptr(pull.altSnapshotFolder)
	pa.WorkingDirectory = model.Ptr(pull.workDir)
	pa.UseFTP = model.Ptr(pull.useFTP != 0)
	pa.EnabledForSyncmgr = model.Ptr(pull.syncmgr != 0)
	c := &model.Connection{Security: model.Ptr(decode.SecurityMode(pull.distributorSecurity))}
	if pull.distributorSecurity == 0 {
		c.Login = model.Ptr(pull.distributorLogin)
		c.PasswordSecret = model.Ptr(e.secret(model.Join(model.Join(path, "distributor_connection"), "password_secret"),
			"SQL", pull.distributor, pull.distributorLogin))
	}
	pa.DistributorConnection = c
	return pa, nil
}
