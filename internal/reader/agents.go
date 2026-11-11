package reader

import (
	"database/sql"
	"fmt"
	"sort"
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

	if r.jobID == "" {
		e.find(model.FindingIncomplete, path, "%s: no SQL Server Agent job recorded", label)
		return a, nil
	}
	var jobName, runAs, command string
	var stepFound int
	err := e.src.Distributor.QueryRowContext(e.ctx, qJob, r.jobID, r.stepUID).Scan(&jobName, &runAs, &command, &stepFound)
	if err == sql.ErrNoRows {
		e.find(model.FindingIncomplete, path, "%s: job %s recorded by replication no longer exists in msdb", label, r.jobID)
		return a, nil
	}
	if err != nil {
		return a, err
	}
	a.JobName = model.Ptr(jobName)
	if stepFound == 0 {
		// Without a step, run_as and command were not read: they stay nil,
		// since "" for run_as would claim the Agent service account.
		e.find(model.FindingIncomplete, path, "%s: job %s has no replication step; command and run-as account not exported", label, jobName)
	} else {
		a.RunAs = model.Ptr(runAs)
		a.Command = model.Ptr(maskPasswords(strings.TrimSpace(command)))
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

func (e *exporter) readLogReaderAgent() error {
	var name string
	var r agentRow
	err := e.src.Distributor.QueryRowContext(e.ctx, e.distQuery(qLogReaderAgent), e.publisherID, e.src.Database).Scan(
		&name, &r.securityMode, &r.login, &r.profileID, &r.jobID, &r.stepUID)
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
			&f.row.jobID, &f.row.stepUID); err != nil {
			rows.Close()
			return err
		}
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
			&f.streams, &f.memoryOptimized); err != nil {
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
