package reader

import (
	"database/sql"
	"fmt"
	"sort"
	"strings"

	"github.com/rudi-bruchez/sqlserver-replication/internal/decode"
	"github.com/rudi-bruchez/sqlserver-replication/internal/state"
)

// newFacts returns facts with empty lists, not nil ones: an empty
// configuration writes [] rather than null.
func newFacts() *state.Facts {
	return &state.Facts{
		Publications:  []state.PublicationFacts{},
		Subscriptions: []state.SubscriptionFacts{},
		Agents:        []state.AgentFacts{},
		ProfileUses:   []state.ProfileUse{},
	}
}

// jobState builds the state of a job from its sysjobs and sysjobactivity
// columns: running when the activity row of the latest Agent session has a
// start and no stop.
func jobState(exists bool, enabled int, start, stop sql.NullTime) state.JobState {
	if !exists {
		return state.JobState{}
	}
	return state.JobState{Exists: true, Enabled: enabled != 0, Running: start.Valid && !stop.Valid}
}

// readJobState reads the state of a job in the msdb of db. A job_id that
// replication keeps without a job gives Exists false.
func (e *exporter) readJobState(db *sql.DB, jobID string) (state.JobState, error) {
	var enabled int
	var start, stop sql.NullTime
	err := db.QueryRowContext(e.ctx, qJobState, jobID).Scan(&enabled, &start, &stop)
	if err == sql.ErrNoRows {
		return jobState(false, 0, start, stop), nil
	}
	if err != nil {
		return state.JobState{}, fmt.Errorf("job state of %s: %w", jobID, err)
	}
	return jobState(true, enabled, start, stop), nil
}

// recordAgent records the facts of an agent with its job state. Nothing is
// recorded when the facts are not read.
func (e *exporter) recordAgent(f *state.AgentFacts, job *state.JobState) {
	if f == nil || e.facts == nil {
		return
	}
	f.Job = job
	e.facts.Agents = append(e.facts.Agents, *f)
}

// recordUnreadPull records a pull agent whose job could not be read at the
// subscriber (not connected, or its row there not readable), from its row at
// the distributor: Job is nil. Without a distributor row there is nothing to
// record.
func (e *exporter) recordUnreadPull(f *state.AgentFacts, d *pullDistRow) {
	if d == nil {
		return
	}
	f.AgentID = d.id
	e.recordAgent(f, nil)
}

// readReadAt reads the time of the facts at the distributor.
func (e *exporter) readReadAt() error {
	if e.facts == nil || e.src.Distributor == nil {
		return nil
	}
	return e.src.Distributor.QueryRowContext(e.ctx, qReadAt).Scan(&e.facts.ReadAt)
}

// readFacts reads the facts that are not read with the agents: the
// publications' snapshot state, the subscription rows, the agents' history
// and the profile uses. Nothing is read when the facts are not asked for.
func (e *exporter) readFacts() error {
	if e.facts == nil {
		return nil
	}
	steps := []struct {
		what string
		fn   func() error
	}{
		{"publications", e.readPublicationFacts},
		{"subscriptions", e.readSubscriptionFacts},
		{"agent history", e.readAgentHistory},
		{"profile uses", e.readProfileUses},
	}
	for _, s := range steps {
		if err := s.fn(); err != nil {
			return fmt.Errorf("%s: %w", s.what, err)
		}
	}
	return nil
}

func (e *exporter) readPublicationFacts() error {
	ready := map[string]bool{}
	rows, err := e.src.Publisher.QueryContext(e.ctx, qPublicationFacts)
	if err != nil {
		return err
	}
	for rows.Next() {
		var name string
		var r int
		if err := rows.Scan(&name, &r); err != nil {
			rows.Close()
			return err
		}
		ready[name] = r != 0
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	articles := map[string][]state.ArticleFacts{}
	rows, err = e.src.Publisher.QueryContext(e.ctx, qArticleFacts)
	if err != nil {
		return err
	}
	for rows.Next() {
		var pubid, active int
		var name string
		if err := rows.Scan(&pubid, &name, &active); err != nil {
			rows.Close()
			return err
		}
		p := e.publication(pubid)
		if p == nil {
			continue
		}
		articles[p.Name] = append(articles[p.Name], state.ArticleFacts{Name: name, Active: active != 0})
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	snapshotAgent := map[string]int{}
	for _, a := range e.facts.Agents {
		if a.Kind == "snapshot" {
			snapshotAgent[a.Publication] = a.AgentID
		}
	}
	for _, p := range e.cfg.Publications {
		pf := state.PublicationFacts{Name: p.Name, ImmediateSyncReady: ready[p.Name], Articles: articles[p.Name]}
		if pf.Articles == nil {
			pf.Articles = []state.ArticleFacts{}
		}
		sort.Slice(pf.Articles, func(i, j int) bool { return pf.Articles[i].Name < pf.Articles[j].Name })
		if id, ok := snapshotAgent[p.Name]; ok {
			err := e.src.Distributor.QueryRowContext(e.ctx, e.distQuery(qLastGeneration), id).Scan(&pf.LastGeneration)
			if err != nil && err != sql.ErrNoRows {
				return err
			}
		}
		e.facts.Publications = append(e.facts.Publications, pf)
	}
	return nil
}

// subscriptionRow is a row of qSubscriptionStatus or
// qDistributorSubscriptionStatus.
type subscriptionRow struct {
	publication, article, subscriber, database string
	status                                     int
}

// matches tells whether two rows are of the same subscribed article: server
// and database names compared case-insensitively, as the replication
// procedures do, publication and article names exactly.
func (r subscriptionRow) matches(publication, subscriber, database string) bool {
	return r.publication == publication && strings.EqualFold(r.subscriber, subscriber) &&
		strings.EqualFold(r.database, database)
}

func (e *exporter) readSubscriptionFacts() error {
	var pubRows []subscriptionRow
	rows, err := e.src.Publisher.QueryContext(e.ctx, qSubscriptionStatus)
	if err != nil {
		return err
	}
	for rows.Next() {
		var pubid int
		var r subscriptionRow
		if err := rows.Scan(&pubid, &r.article, &r.subscriber, &r.database, &r.status); err != nil {
			rows.Close()
			return err
		}
		p := e.publication(pubid)
		if p == nil {
			continue
		}
		r.publication = p.Name
		pubRows = append(pubRows, r)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	var distRows []subscriptionRow
	rows, err = e.src.Distributor.QueryContext(e.ctx, e.distQuery(qDistributorSubscriptionStatus), e.publisherID, e.src.Database)
	if err != nil {
		return err
	}
	for rows.Next() {
		var r subscriptionRow
		if err := rows.Scan(&r.publication, &r.article, &r.subscriber, &r.database, &r.status); err != nil {
			rows.Close()
			return err
		}
		distRows = append(distRows, r)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}

	for _, p := range e.cfg.Publications {
		for _, s := range p.Subscriptions {
			sf := state.SubscriptionFacts{Publication: p.Name, Subscriber: s.Subscriber, Database: s.Database,
				Rows: []state.SubscriptionRow{}}
			var mine []subscriptionRow
			for _, r := range pubRows {
				if r.matches(p.Name, s.Subscriber, s.Database) {
					mine = append(mine, r)
				}
			}
			sort.Slice(mine, func(i, j int) bool { return mine[i].article < mine[j].article })
			// A left join: one row per matching distributor row, so that a
			// duplicate at the distributor shows instead of being hidden.
			for _, r := range mine {
				matched := false
				for _, d := range distRows {
					if d.article == r.article && d.matches(r.publication, r.subscriber, r.database) {
						status := d.status
						sf.Rows = append(sf.Rows, state.SubscriptionRow{Article: r.article, PublisherStatus: r.status, DistributorStatus: &status})
						matched = true
					}
				}
				if !matched {
					sf.Rows = append(sf.Rows, state.SubscriptionRow{Article: r.article, PublisherStatus: r.status})
				}
			}
			e.facts.Subscriptions = append(e.facts.Subscriptions, sf)
		}
	}
	return nil
}

// historyQuery returns the history query of an agent kind. A pull agent
// writes its history at the distributor too.
func historyQuery(kind string) string {
	switch kind {
	case "log_reader":
		return qLogReaderHistory
	case "snapshot":
		return qSnapshotHistory
	}
	return qDistributionHistory
}

func (e *exporter) readAgentHistory() error {
	for i := range e.facts.Agents {
		a := &e.facts.Agents[i]
		if a.AgentID == 0 {
			continue
		}
		q := e.distQuery(historyQuery(a.Kind))
		for failure, dst := range []**state.HistoryRow{&a.LastHistory, &a.LastFailure} {
			var h state.HistoryRow
			err := e.src.Distributor.QueryRowContext(e.ctx, q, a.AgentID, failure).Scan(&h.Time, &h.RunStatus, &h.Comments, &h.ErrorText)
			if err == sql.ErrNoRows {
				continue
			}
			if err != nil {
				return err
			}
			*dst = &h
		}
	}
	return nil
}

// readProfileUses reads the agents of every distribution database of the
// distributor that use a user-defined profile.
func (e *exporter) readProfileUses() error {
	var dbs []string
	rows, err := e.src.Distributor.QueryContext(e.ctx, qDistributionDBs)
	if err != nil {
		return err
	}
	for rows.Next() {
		var name string
		if err := rows.Scan(&name); err != nil {
			rows.Close()
			return err
		}
		dbs = append(dbs, name)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	if len(dbs) == 0 {
		return nil
	}

	// Every distribution database of an instance has the same version, so
	// whether {dist} has MSreplservers stands for all of them.
	rows, err = e.src.Distributor.QueryContext(e.ctx, profileUsesQuery(dbs, e.servers == fallbackServers))
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var i, agentType, virtual int
		var u state.ProfileUse
		if err := rows.Scan(&i, &u.Profile, &agentType, &u.Publisher, &u.PublisherDB, &u.Publication,
			&u.Subscriber, &u.Database, &virtual); err != nil {
			return err
		}
		u.Virtual = virtual != 0
		u.AgentType = decode.AgentType(agentType)
		u.DistributionDB = dbs[i]
		e.facts.ProfileUses = append(e.facts.ProfileUses, u)
	}
	if err := rows.Err(); err != nil {
		return err
	}
	sort.Slice(e.facts.ProfileUses, func(i, j int) bool {
		a, b := e.facts.ProfileUses[i], e.facts.ProfileUses[j]
		for _, c := range [][2]string{{a.Profile, b.Profile}, {a.AgentType, b.AgentType}, {a.DistributionDB, b.DistributionDB},
			{a.Publisher, b.Publisher}, {a.PublisherDB, b.PublisherDB}, {a.Publication, b.Publication},
			{a.Subscriber, b.Subscriber}, {a.Database, b.Database}} {
			if c[0] != c[1] {
				return c[0] < c[1]
			}
		}
		return !a.Virtual && b.Virtual
	})
	return nil
}
