package reader

import (
	"database/sql"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"

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
}

// agent builds the model of an agent: profile, job, run-as account, command
// line and schedules. path is the path of the agent, and secretParts the
// parts of the name of its password secret when it uses SQL Server
// authentication.
func (e *exporter) agent(path, label string, r agentRow, secretParts ...string) (model.Agent, error) {
	a := model.Agent{Profile: model.Ptr(e.profileName(model.Join(path, "profile"), r.profileID))}
	a.Connection = &model.Connection{Security: model.Ptr(decode.SecurityMode(r.securityMode)), Login: model.Ptr(r.login)}
	if r.securityMode == 0 {
		a.Connection.PasswordSecret = model.Ptr(e.secret(model.Join(model.Join(path, "connection"), "password_secret"),
			"SQL", append(secretParts, r.login)...))
	}

	a.JobLogin = model.Ptr(r.jobLogin)
	if r.jobLogin != "" {
		a.JobPasswordSecret = model.Ptr(e.secret(model.Join(path, "job_password_secret"), "WIN", r.jobLogin))
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
	err := e.src.Distributor.QueryRowContext(e.ctx, qJob, r.jobID, r.stepUID).Scan(
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
		} else {
			// "" would claim the Agent service account: run_as stays nil.
			e.find(model.FindingUnreadable, model.Join(path, "run_as"),
				"the job step runs under proxy %d, whose credential this login cannot see", proxyID.Int32)
		}
		a.Command = model.Ptr(maskPasswords(strings.TrimSpace(command)))
		if r.snapshot {
			e.distributorConnection(path, &a, command)
		}
	}

	rows, err := e.src.Distributor.QueryContext(e.ctx, qJobSchedules, r.jobID)
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
// distributor from the switches of its command line. An absent security mode
// is 1, Windows authentication. Whatever cannot be read leaves
// distributor_connection (or its login) nil with an unreadable finding: never
// a default and never a secret name built from a guess.
func (e *exporter) distributorConnection(path string, a *model.Agent, command string) {
	cpath := model.Join(path, "distributor_connection")
	unreadable := func(p, format string, args ...any) {
		e.find(model.FindingUnreadable, p, format, args...)
	}
	// A switch name glued to the text before it is not a switch the server
	// wrote: reading around it could default a SQL connection to Windows.
	for _, name := range []string{"Distributor", "DistributorSecurityMode", "DistributorLogin"} {
		if gluedSwitch(command, name) {
			unreadable(cpath, "-%s is not preceded by whitespace in the command line", name)
			return
		}
	}
	// -Distributor is bracketed by the server: an unbalanced bracket or quote
	// means the line is not what the server wrote.
	if _, present, balanced := bracketedSwitch(command, "Distributor"); present && !balanced {
		unreadable(cpath, "the command line has an unbalanced bracket or quote after -Distributor")
		return
	}
	mode := 1
	if rest, present := switchStart(command, "DistributorSecurityMode"); present {
		// The value is the first token: the step can carry other switches
		// after it (-OutputVerboseLevel 2).
		v := rest
		if i := strings.IndexAny(rest, " \t\r\n"); i >= 0 {
			v = rest[:i]
		}
		n, err := strconv.Atoi(v)
		if err != nil {
			unreadable(cpath, "-DistributorSecurityMode %q is not a number", v)
			return
		}
		mode = n
	}
	c := &model.Connection{Security: model.Ptr(decode.SecurityMode(mode))}
	if mode == 0 {
		a.DistributorConnection = c
		login, ok := loginSwitch(command)
		if !ok {
			unreadable(model.Join(cpath, "login"), "the -DistributorLogin value of the command line cannot be told from the other switches")
			return
		}
		c.Login = model.Ptr(login)
		distributor := ""
		if e.cfg.Distributor != nil {
			distributor = e.cfg.Distributor.Server
		}
		c.PasswordSecret = model.Ptr(e.secret(model.Join(cpath, "password_secret"), "SQL", distributor, login))
		return
	}
	a.DistributorConnection = c
}

var (
	loginEnd    = regexp.MustCompile(`(?i)\s[-/]DistributorPassword(?:\s|$)`)
	otherSwitch = regexp.MustCompile(`\s[-/][A-Za-z]`)
)

// loginSwitch reads -DistributorLogin, which the server writes raw, as
// " -DistributorLogin <login> -DistributorPassword <password>" (measured): the
// login is the text up to the following password switch. ok is false when the
// switch is absent or empty, no password switch follows, the span holds
// another switch-like token, or the value contains "password": the login
// cannot then be told from the rest of the line. The first occurrence of a
// repeated switch is kept; which one the agent honours is not measured.
func loginSwitch(cmd string) (login string, ok bool) {
	rest, present := switchStart(cmd, "DistributorLogin")
	if !present {
		return "", false
	}
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
	find := func(publication, subscriber, database string) *found {
		for k := range all {
			f := &all[k]
			if f.subscriptionType == 0 && f.publication == publication &&
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

	// A shared agent serves every non-independent publication of the
	// database for one subscriber database: it is exported once.
	shared := map[[2]string]bool{}
	for i := range e.cfg.Publications {
		p := &e.cfg.Publications[i]
		for j := range p.Subscriptions {
			s := &p.Subscriptions[j]
			label := fmt.Sprintf("publication %s, subscription %s.%s", p.Name, s.Subscriber, s.Database)
			if *p.IndependentAgent {
				path := model.Join(subscriptionPath(p.Name, s.Subscriber, s.Database), "distribution_agent")
				f := find(p.Name, s.Subscriber, s.Database)
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
			f := find("ALL", s.Subscriber, s.Database)
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
	sort.Slice(e.cfg.Publisher.SharedDistributionAgents, func(i, j int) bool {
		a, b := e.cfg.Publisher.SharedDistributionAgents[i], e.cfg.Publisher.SharedDistributionAgents[j]
		if a.Subscriber != b.Subscriber {
			return a.Subscriber < b.Subscriber
		}
		return a.Database < b.Database
	})
	return nil
}
