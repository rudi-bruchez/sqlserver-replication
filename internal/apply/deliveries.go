package apply

import (
	"bytes"
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	mssql "github.com/microsoft/go-mssqldb"

	"github.com/rudi-bruchez/sqlserver-replication/internal/plan"
)

// The deliveries owed (R50). For each delivery a plan owes, apply records
// at the distributor T (GETDATE(), a datetime as the history's time is),
// the mark (the highest rowversion of MSdistribution_history), whether the
// publication's snapshot job runs, and the run folders of the publication's
// snapshot folder (folders.go). It then polls the history every second and
// keeps every "Delivered snapshot" line it sees, since the line is never
// rewritten in place (panel M). A delivery is confirmed by a kept line of
// the subscription's agent above the mark, at or after T, that names the
// publication's folder and a run acceptRun accepts; under concurrent and
// concurrent_c, the subscription's MSsubscriptions rows must also read
// status 2. A pull agent writes its line to the distributor's history like
// a push agent (Task 3 row DL.pull.delivered_line yes), and the line of a
// shared agent's re-added subscription is found by the mark and the folder
// rule, whether the agent was recreated or kept (DL.shared_readd and
// DL.shared_readd_kept yes).

// owed is one delivery owed, as recorded.
type owed struct {
	Publication, Subscription string
	T                         time.Time // GETDATE() read at the distributor (R50)
	Mark                      []byte    // rowversion; a history row is (agent_id, timestamp)
	Folder                    string    // the publication's folder, by R50's rule
	Listing                   []string  // run folders at T
	RunningAtT, S7            bool      // RunningAtT: retaken once the job is idle, never confirmed before
	Created, Concurrent       bool      // Created: the plan creates the publication
	// NoRun: the publication exists before the plan and has no run yet, its
	// folder absent from a listing that shows <root>/unc (R50a): its
	// listing at T is empty and its folder is identified later, as for a
	// created one.
	NoRun bool
}

// Delivery is the outcome of one delivery owed, for the end of the run
// (R53).
type Delivery struct {
	Publication, Subscription string
	Status                    string // confirmed, unconfirmed, not_awaited
	Run, Detail               string
	// JobState and LastHistory are read at the end for a delivery not
	// confirmed (R53): the agent job's state (idle, running, unknown) and
	// the comments of its agents' last history row.
	JobState, LastHistory string
}

// The statuses of a Delivery.
const (
	deliveryConfirmed   = "confirmed"
	deliveryUnconfirmed = "unconfirmed"
	deliveryNotAwaited  = "not_awaited"
)

// The "Delivered snapshot" line a distribution agent writes, measured on
// the lab (Task 3): Delivered snapshot from the
// 'unc\<folder>\<run>\' sub-folder in <n> milliseconds.
const (
	deliveredPrefix = "Delivered snapshot from the '"
	deliveredEnd    = "' sub-folder"
)

// parseDelivered reads the publication folder and the run of a "Delivered
// snapshot" line; ok is false for any other comment. A name with a space
// is kept (O19). Only \ is measured as the separator (the lab, Linux
// included); / is accepted too, unmeasured.
func parseDelivered(comments string) (pubFolder, run string, ok bool) {
	if !strings.HasPrefix(comments, deliveredPrefix) {
		return "", "", false
	}
	end := strings.LastIndex(comments, deliveredEnd)
	if end < len(deliveredPrefix) {
		return "", "", false
	}
	inner := strings.ReplaceAll(comments[len(deliveredPrefix):end], "/", `\`)
	parts := strings.Split(strings.TrimSuffix(inner, `\`), `\`)
	if len(parts) != 3 || !strings.EqualFold(parts[0], "unc") || parts[1] == "" || parts[2] == "" {
		return "", "", false
	}
	return parts[1], parts[2], true
}

// runLayout is the name of a run folder: the snapshot agent's start time,
// yyyyMMddHHmmss, on the distributor's clock (R50c).
const runLayout = "20060102150405"

// acceptRun tells whether a delivered run of the publication's folder
// confirms o (R50): never while a run was in progress at T (the record is
// retaken once the job is idle); any run for an S7 subscription (Task 3
// row DL.s7_frequent: its run was already listed at T, so R50c does not
// apply to it); otherwise only a run absent from the listing at T whose
// name, read as yyyyMMddHHmmss, is not earlier than T truncated to the
// second (R50c): the name is the one fact a folder unreadable at T, whose
// listing shows no run, cannot hide (final review, I1). A name that does
// not parse is not accepted. Both clocks are the distributor's: T is its
// GETDATE(), the name its snapshot agent's.
func acceptRun(o owed, run string) bool {
	if o.RunningAtT {
		return false
	}
	if o.S7 {
		return true
	}
	at, err := time.ParseInLocation(runLayout, run, o.T.Location())
	if err != nil || at.Before(o.T.Truncate(time.Second)) {
		return false
	}
	for _, r := range o.Listing {
		if strings.EqualFold(r, run) {
			return false
		}
	}
	return true
}

// record is an owed delivery and what the polls found for it.
type record struct {
	owed
	agents       []int  // its distribution agent rows; nil until read
	run          string // <folder>\<run> once confirmed
	unlisted     string // why it can never be confirmed (the folder rule, or a failed generation, R51a)
	concurrentOK bool   // its MSsubscriptions rows read status 2
	jobState     string // read at the end by describe: idle, running, unknown
	lastHistory  string // read at the end by describe
}

// line is a "Delivered snapshot" line of the history, kept as seen.
type line struct {
	agent    int
	ts       []byte
	time     time.Time
	comments string
}

type lineKey struct {
	agent int
	ts    string
}

// tracker holds the deliveries owed of a run and every line its polls
// kept.
type tracker struct {
	distributor string // the distributor's server name, its pinned connection
	publisher   string // the publisher's name, the first part of its folder names
	servers     string // {servers}: "" for MSreplservers, else fallbackServers
	probed      bool
	records     []*record
	roots       map[string]string // by publication, the root read at T when the plan gives none (R50b)
	lines       map[lineKey]line
	order       []lineKey // lines in the order seen
}

// newTracker reads at distributor, the server name of the distributor as
// the file writes it, and names the snapshot folders after publisher, the
// publisher's name (fix round 1 of Task 8). Task 9 passes the plan's
// Publisher: Build has checked it equal to the publisher's @@SERVERNAME
// without regard to case (R7), and the folder match ignores case.
func newTracker(distributor, publisher string) *tracker {
	return &tracker{distributor: distributor, publisher: publisher, roots: map[string]string{}, lines: map[lineKey]line{}}
}

// keep adds a line not seen yet.
func (t *tracker) keep(l line) {
	k := lineKey{agent: l.agent, ts: string(l.ts)}
	if _, ok := t.lines[k]; ok {
		return
	}
	t.lines[k] = l
	t.order = append(t.order, k)
}

// moment is what record reads for a publication at T.
type moment struct {
	t                   time.Time
	mark                []byte
	running             bool
	folder              string
	listing             []string
	unlisted            string
	created, concurrent bool
	noRun               bool
}

// serversTable decides {servers} once, by reading MSreplservers (error 208
// is absence), as internal/reader does.
func (t *tracker) serversTable(ctx context.Context, s *session, p *plan.Plan) (string, error) {
	if t.probed {
		return t.servers, nil
	}
	conn, err := s.conn(ctx, t.distributor)
	if err != nil {
		return "", err
	}
	if _, err := conn.ExecContext(ctx, distQuery(qReplServersProbe, p.DistributionDB, "")); err != nil {
		de, ok := driverError(err)
		if !ok || de.Number != msg208 {
			return "", fmt.Errorf("read whether MSreplservers exists: %w", err)
		}
		t.servers = fallbackServers
	}
	t.probed = true
	return t.servers, nil
}

// take reads T and the mark in one statement, then whether the snapshot
// job of pub runs, then the listing of its roots, then whether its
// sync_method is concurrent or concurrent_c. A run that starts after the
// job read is a run after T, which a delivery may confirm; one in progress
// at the read is refused by RunningAtT.
func (t *tracker) take(ctx context.Context, s *session, p *plan.Plan, pub string) (moment, error) {
	var m moment
	conn, err := s.conn(ctx, t.distributor)
	if err != nil {
		return m, err
	}
	if err := conn.QueryRowContext(ctx, distQuery(qTMark, p.DistributionDB, "")).Scan(&m.t, &m.mark); err != nil {
		return m, fmt.Errorf("read T and the mark: %w", err)
	}
	if lookup, ok := p.SnapshotJobLookup(pub); ok {
		var idle int
		if err := conn.QueryRowContext(ctx, idleQuery(lookup)).Scan(&idle); err != nil {
			// The lookup throws 50000 when the job does not exist: a job
			// that does not exist does not run.
			if de, ok := driverError(err); !ok || de.Number != 50000 {
				return m, fmt.Errorf("read whether the snapshot job of %s runs: %w", pub, err)
			}
		} else {
			m.running = idle == 0
		}
	}
	m.created = createdBy(p, pub)
	if err := t.list(ctx, s, p, pub, &m); err != nil {
		return m, err
	}
	m.concurrent, err = concurrentMethod(ctx, s, p, pub)
	return m, err
}

// concurrentMethod tells whether the sync_method of pub is concurrent or
// concurrent_c (codes 3 and 4), read at the publisher; false when the
// publication does not exist.
func concurrentMethod(ctx context.Context, s *session, p *plan.Plan, pub string) (bool, error) {
	conn, err := s.connIn(ctx, p.Publisher, p.Database)
	if err != nil {
		return false, err
	}
	var method int
	switch err := conn.QueryRowContext(ctx, qSyncMethod, pub).Scan(&method); {
	case errors.Is(err, sql.ErrNoRows):
		return false, nil
	case err != nil:
		return false, fmt.Errorf("read the sync_method of %s: %w", pub, err)
	}
	return method == 3 || method == 4, nil
}

// list fills the folder and the run folders of pub at T. When the plan
// changes the root, both roots are listed and a run present in either is
// refused (controller's ruling, review of Task 4). A publication that
// exists before the plan and whose folder no root shows can never be
// confirmed, unless a root's listing shows its unc directory (R50a,
// fromListings); one the plan creates has no run before T, and its folder
// is identified by a later poll. A publication whose plan gives no root is
// listed under the publisher's working_directory read now (R50b).
func (t *tracker) list(ctx context.Context, s *session, p *plan.Plan, pub string, m *moment) error {
	root := p.SnapshotRoots[pub]
	if root == "" {
		var err error
		if root, err = t.publisherRoot(ctx, s); err != nil {
			return err
		}
		t.roots[pub] = root
	}
	var roots []string
	for _, r := range []string{root, p.SnapshotRootsBefore[pub]} {
		if r == "" {
			continue
		}
		dup := false
		for _, have := range roots {
			dup = dup || samePath(have, r)
		}
		if !dup {
			roots = append(roots, r)
		}
	}
	if len(roots) == 0 {
		m.unlisted = fmt.Sprintf("snapshot folder of %s cannot be listed: its snapshot root is unknown", pub)
		return nil
	}
	var ls []rootListing
	for _, root := range roots {
		entries, err := listRoot(ctx, s, t.distributor, root)
		if err != nil {
			return err
		}
		ls = append(ls, rootListing{root: root, entries: entries})
	}
	m.fromListings(ls, t.publisher, p.Database, pub)
	return nil
}

// publisherRoot reads the publisher's working_directory at the distributor
// (R50b): the root of a publication whose plan gives none, because the file
// omitted working_directory and the distributor took its default (Task 13).
// "" when the row is missing or NULL: the root stays unknown.
func (t *tracker) publisherRoot(ctx context.Context, s *session) (string, error) {
	conn, err := s.conn(ctx, t.distributor)
	if err != nil {
		return "", err
	}
	var wd sql.NullString
	switch err := conn.QueryRowContext(ctx, qPublisherRoot, t.publisher).Scan(&wd); {
	case errors.Is(err, sql.ErrNoRows):
		return "", nil
	case err != nil:
		return "", fmt.Errorf("read the working_directory of %s: %w", t.publisher, err)
	}
	return wd.String, nil
}

// rootListing is the listing of one snapshot root at T.
type rootListing struct {
	root    string
	entries []fsEntry
}

// fromListings fills the folder, the run folders, unlisted and noRun of
// pub from the listings of its roots at T (R50, R50a). A folder found in
// no listing: for a publication the plan creates, nothing (an empty
// listing); for one that exists before the plan, noRun when every listing
// shows its <root>/unc (a root that lists 0 rows beside one that shows unc
// could hold the old runs: Task 12 review, Important 1) (the root is readable and the publication has no run
// yet: a folder that cannot be read still shows as a child of its parent,
// measured by the controller on repllab with chmod 000), else unlisted,
// "snapshot folder of <publication> cannot be listed at <roots>" (a
// missing or unreadable root lists 0 rows).
func (m *moment) fromListings(ls []rootListing, publisher, database, pub string) {
	// Every root must show its unc directory (fix round 2 of Task 12): a
	// root that lists 0 rows may hold old runs the engine cannot see.
	unc := len(ls) > 0
	var roots []string
	for _, l := range ls {
		roots = append(roots, l.root)
		path, err := pubFolder(l.entries, l.root, publisher, database, pub)
		switch {
		case isNoFolder(err):
			unc = unc && hasUnc(l.entries, l.root)
			continue
		case err != nil:
			m.unlisted = err.Error()
			return
		}
		if m.folder == "" {
			m.folder = folderName(path)
		}
		m.listing = append(m.listing, runFolders(l.entries, path)...)
	}
	if m.folder != "" || m.created {
		return
	}
	if unc {
		m.noRun = true
		return
	}
	m.unlisted = noFolderError{publication: pub, path: strings.Join(roots, " and ")}.Error()
}

// createdBy tells whether the plan creates the publication.
func createdBy(p *plan.Plan, pub string) bool {
	for _, op := range p.Operations {
		if op.Kind == "publication" && op.Action == "add" && strings.EqualFold(firstString(op.Affects.Publications), pub) {
			return true
		}
	}
	return false
}

func firstString(xs []string) string {
	if len(xs) == 0 {
		return ""
	}
	return xs[0]
}

// connIn is the pinned connection of server with database current.
func (s *session) connIn(ctx context.Context, server, database string) (*sql.Conn, error) {
	pc, err := s.pin(ctx, server)
	if err != nil {
		return nil, err
	}
	if err := s.use(ctx, pc, database); err != nil {
		return nil, err
	}
	return pc.conn, nil
}

func (r *record) set(m moment) {
	r.T, r.Mark, r.RunningAtT = m.t, m.mark, m.running
	r.Folder, r.Listing, r.unlisted = m.folder, m.listing, m.unlisted
	r.Created, r.Concurrent, r.NoRun = m.created, m.concurrent, m.noRun
}

// record records the deliveries owed to subs by pub (R50): T, the mark,
// the folder, the listing and whether the snapshot job runs, read once for
// all of them. A delivery still pending for the same subscription is
// replaced: the later operation owes a run after it.
func (t *tracker) record(ctx context.Context, s *session, p *plan.Plan, pub string, subs []string) error {
	if len(subs) == 0 {
		return nil
	}
	m, err := t.take(ctx, s, p, pub)
	if err != nil {
		return err
	}
	for _, sub := range subs {
		r := t.find(pub, sub)
		if r == nil {
			r = &record{}
			t.records = append(t.records, r)
		}
		*r = record{owed: owed{Publication: pub, Subscription: sub}}
		r.set(m)
	}
	return nil
}

// find is the pending record of pub and sub, nil when none.
func (t *tracker) find(pub, sub string) *record {
	for _, r := range t.records {
		if r.run == "" && strings.EqualFold(r.Publication, pub) && strings.EqualFold(r.Subscription, sub) {
			return r
		}
	}
	return nil
}

// retake reads T, the mark, the listing and the job again for the pending
// records of pub whose snapshot job ran at T, once that run has ended
// (R50), before apply starts its own run: the run in progress at T is
// then listed, and refused. S7 and the agents are kept.
func (t *tracker) retake(ctx context.Context, s *session, p *plan.Plan, pub string) error {
	var due []*record
	for _, r := range t.records {
		if r.run == "" && r.RunningAtT && strings.EqualFold(r.Publication, pub) {
			due = append(due, r)
		}
	}
	if len(due) == 0 {
		return nil
	}
	m, err := t.take(ctx, s, p, pub)
	if err != nil {
		return err
	}
	for _, r := range due {
		s7, agents := r.S7, r.agents
		r.set(m)
		r.S7, r.agents = s7, agents
	}
	return nil
}

// settle reads, on the first statement after the unit that creates sub,
// its subscription rows at the publisher: all at status 2 is the S7 case
// (R50, 05-snapshot-flag), whose delivery any run of the publication
// confirms.
func (t *tracker) settle(ctx context.Context, s *session, p *plan.Plan, pub, sub string) error {
	st, err := statuses(ctx, s, p.Publisher, p.Database, pub)
	if err != nil {
		return err
	}
	r := t.find(pub, sub)
	if r == nil {
		return nil
	}
	rows := st[strings.ToLower(sub)]
	r.S7 = len(rows) > 0
	for _, v := range rows {
		r.S7 = r.S7 && v == 2
	}
	return nil
}

// statuses reads the subscription rows of pub at the publisher, by
// lower-cased subscription key (<subscriber>/<database>) and lower-cased
// article name.
func statuses(ctx context.Context, s *session, server, database, pub string) (map[string]map[string]int, error) {
	conn, err := s.connIn(ctx, server, database)
	if err != nil {
		return nil, err
	}
	rows, err := conn.QueryContext(ctx, qSubStatus, pub)
	if err != nil {
		return nil, fmt.Errorf("read the subscription statuses of %s: %w", pub, err)
	}
	defer rows.Close()
	out := map[string]map[string]int{}
	for rows.Next() {
		var srv, db, art string
		var status int
		if err := rows.Scan(&srv, &db, &art, &status); err != nil {
			return nil, fmt.Errorf("read the subscription statuses of %s: %w", pub, err)
		}
		k := strings.ToLower(srv + "/" + db)
		if out[k] == nil {
			out[k] = map[string]int{}
		}
		out[k][strings.ToLower(art)] = status
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read the subscription statuses of %s: %w", pub, err)
	}
	return out, nil
}

// marked reads the subscription rows of op's publication before op, at
// op's server and database (the publisher and the publication database);
// the returned function reads them after op and returns the subscriptions
// of op.Owes that went from 2 to 1 (R50): a row at 2 before and at 1
// after.
func (t *tracker) marked(ctx context.Context, s *session, op plan.Operation) (func(context.Context) ([]string, error), error) {
	pub := firstString(op.Affects.Publications)
	before, err := statuses(ctx, s, op.Server, op.Database, pub)
	if err != nil {
		return nil, err
	}
	return func(ctx context.Context) ([]string, error) {
		after, err := statuses(ctx, s, op.Server, op.Database, pub)
		if err != nil {
			return nil, err
		}
		var went []string
		for _, key := range op.Owes {
			k := strings.ToLower(key)
			for art, b := range before[k] {
				if a, ok := after[k][art]; ok && b == 2 && a == 1 {
					went = append(went, key)
					break
				}
			}
		}
		return went, nil
	}, nil
}

// splitKey splits a subscription key, <subscriber>/<database>: a server
// name has no /, a database name may.
func splitKey(key string) (subscriber, database string) {
	subscriber, database, _ = strings.Cut(key, "/")
	return subscriber, database
}

// poll is one pass (R50): for every record still pending, its agent rows,
// read again at every pass so that a shared agent recreated after a pass is
// seen (DL.shared_readd measured a new id); the history lines of its agents
// above its mark, kept; the publication's sync_method, read again at every
// pass so that the gate follows a change made after the record, and under
// concurrent and concurrent_c the status of its MSsubscriptions rows; the
// folder of a publication the plan creates, until identified. Then every
// pending record is matched against every kept line.
func (t *tracker) poll(ctx context.Context, s *session, p *plan.Plan) error {
	servers, err := t.serversTable(ctx, s, p)
	if err != nil {
		return err
	}
	conn, err := s.conn(ctx, t.distributor)
	if err != nil {
		return err
	}
	for _, r := range t.records {
		if r.run != "" || r.unlisted != "" {
			continue
		}
		sub, subDB := splitKey(r.Subscription)
		ids, err := t.agentRows(ctx, conn, p, servers, r.Publication, sub, subDB)
		if err != nil {
			return err
		}
		r.agents = ids
		for _, a := range r.agents {
			if err := t.history(ctx, conn, p, a, r.Mark); err != nil {
				return err
			}
		}
		if r.Concurrent, err = concurrentMethod(ctx, s, p, r.Publication); err != nil {
			return err
		}
		r.concurrentOK = false
		if r.Concurrent {
			ok, err := t.distStatus(ctx, conn, p, servers, r.Publication, sub, subDB)
			if err != nil {
				return err
			}
			r.concurrentOK = ok
		}
		if r.Folder == "" && (r.Created || r.NoRun) {
			if err := t.identify(ctx, s, p, r); err != nil {
				return err
			}
		}
	}
	t.confirm()
	return nil
}

// agentRows reads the ids of the subscription's agent rows (qAgentRow).
func (t *tracker) agentRows(ctx context.Context, conn *sql.Conn, p *plan.Plan, servers, pub, sub, subDB string) ([]int, error) {
	rows, err := conn.QueryContext(ctx, distQuery(qAgentRow, p.DistributionDB, servers), p.Publisher, p.Database, sub, subDB, pub)
	if err != nil {
		return nil, fmt.Errorf("read the distribution agent of %s to %s/%s: %w", pub, sub, subDB, err)
	}
	defer rows.Close()
	var ids []int
	for rows.Next() {
		var id int
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	return ids, rows.Err()
}

// history keeps the "Delivered snapshot" lines of agent above mark.
func (t *tracker) history(ctx context.Context, conn *sql.Conn, p *plan.Plan, agent int, mark []byte) error {
	rows, err := conn.QueryContext(ctx, distQuery(qHistoryAfter, p.DistributionDB, ""), agent, mark)
	if err != nil {
		return fmt.Errorf("read the history of agent %d: %w", agent, err)
	}
	defer rows.Close()
	for rows.Next() {
		var l line
		if err := rows.Scan(&l.agent, &l.ts, &l.time, &l.comments); err != nil {
			return fmt.Errorf("read the history of agent %d: %w", agent, err)
		}
		t.keep(l)
	}
	return rows.Err()
}

// distStatus tells whether every MSsubscriptions row of the subscription
// reads status 2, false when it has none.
func (t *tracker) distStatus(ctx context.Context, conn *sql.Conn, p *plan.Plan, servers, pub, sub, subDB string) (bool, error) {
	rows, err := conn.QueryContext(ctx, distQuery(qDistSubStatus, p.DistributionDB, servers), p.Publisher, p.Database, pub, sub, subDB)
	if err != nil {
		return false, fmt.Errorf("read the distributor statuses of %s to %s/%s: %w", pub, sub, subDB, err)
	}
	defer rows.Close()
	n, all2 := 0, true
	for rows.Next() {
		var st int
		if err := rows.Scan(&st); err != nil {
			return false, err
		}
		n++
		all2 = all2 && st == 2
	}
	return n > 0 && all2, rows.Err()
}

// identify lists the root of a publication the plan creates, whose folder
// was absent at T, until its folder appears; several folders make the
// record unconfirmed.
func (t *tracker) identify(ctx context.Context, s *session, p *plan.Plan, r *record) error {
	root := p.SnapshotRoots[r.Publication]
	if root == "" {
		root = t.roots[r.Publication] // read at T (R50b)
	}
	if root == "" {
		r.unlisted = fmt.Sprintf("snapshot folder of %s cannot be listed: its snapshot root is unknown", r.Publication)
		return nil
	}
	entries, err := listRoot(ctx, s, t.distributor, root)
	if err != nil {
		return err
	}
	r.identifyIn(entries, root, t.publisher, p.Database)
	return nil
}

// identifyIn sets the folder of r from a listing of root: found, its name;
// absent, nothing yet; not identified, r can never be confirmed.
func (r *record) identifyIn(entries []fsEntry, root, publisher, database string) {
	path, err := pubFolder(entries, root, publisher, database, r.Publication)
	switch {
	case isNoFolder(err):
	case err != nil:
		r.unlisted = err.Error()
	default:
		r.Folder = folderName(path)
	}
}

// confirm matches every pending record against the kept lines, in the
// order seen: a line of one of its agents, above its mark, at or after T,
// naming its folder and a run acceptRun accepts, and under the concurrent
// family its rows at 2.
func (t *tracker) confirm() {
	for _, r := range t.records {
		if r.run != "" || r.unlisted != "" || r.Folder == "" || (r.Concurrent && !r.concurrentOK) {
			continue
		}
		for _, k := range t.order {
			l := t.lines[k]
			if !hasAgent(r.agents, l.agent) || bytes.Compare(l.ts, r.Mark) <= 0 || l.time.Before(r.T) {
				continue
			}
			folder, run, ok := parseDelivered(l.comments)
			if !ok || !strings.EqualFold(folder, r.Folder) || !acceptRun(r.owed, run) {
				continue
			}
			r.run = r.Folder + `\` + run
			break
		}
	}
}

func hasAgent(agents []int, a int) bool {
	for _, x := range agents {
		if x == a {
			return true
		}
	}
	return false
}

// failureQuery is the lookup of a snapshot job followed by
// qJobFailedAfter (R51a).
func failureQuery(lookup string) string {
	return strings.TrimRight(lookup, "\n") + "\n" + qJobFailedAfter
}

// generationFailed ends at once every record of recs still pending whose
// publication's snapshot job has a failed job outcome (step 0) for a run
// that started at or after the record's T (R51a): it can no longer be
// confirmed by the run it waits for, and its detail names the job's last
// history message. T is passed back as a datetime, the type it was read
// as, and compared on the distributor (qJobFailedAfter). An S7 record,
// which any run confirms, and a record whose job ran at T, which is
// retaken with a later T, are not read. A job the lookup does not find
// (50000) has no outcome.
func (t *tracker) generationFailed(ctx context.Context, s *session, p *plan.Plan, recs []*record) error {
	var conn *sql.Conn
	for _, r := range recs {
		if r.run != "" || r.unlisted != "" || r.S7 || r.RunningAtT {
			continue
		}
		lookup, ok := p.SnapshotJobLookup(r.Publication)
		if !ok {
			continue
		}
		if conn == nil {
			var err error
			if conn, err = s.conn(ctx, t.distributor); err != nil {
				return err
			}
		}
		var at time.Time
		var msg string
		switch err := conn.QueryRowContext(ctx, failureQuery(lookup), mssql.DateTime1(r.T)).Scan(&at, &msg); {
		case errors.Is(err, sql.ErrNoRows):
			continue
		case err != nil:
			if de, ok := driverError(err); ok && de.Number == 50000 {
				continue
			}
			return fmt.Errorf("read the outcome of the snapshot job of %s: %w", r.Publication, err)
		}
		r.unlisted = fmt.Sprintf("the snapshot job of %s failed, run started %s: %s", r.Publication, at.Format("2006-01-02 15:04:05"), msg)
	}
	return nil
}

// pending is the deliveries of pub still awaited: neither confirmed nor
// known never to be (a folder the rule cannot identify).
func (t *tracker) pending(pub string) []owed {
	var out []owed
	for _, r := range t.records {
		if r.run == "" && r.unlisted == "" && strings.EqualFold(r.Publication, pub) {
			out = append(out, r.owed)
		}
	}
	return out
}

// results is the outcome of every delivery owed, in the order recorded:
// confirmed with its run; unconfirmed with its reason when it can never be
// confirmed (its folder not identified or not listable), with notAwaited
// too, since waiting would not have changed it; otherwise, with notAwaited
// (-wait 0, R52), not_awaited, else unconfirmed with the reason.
func (t *tracker) results(notAwaited bool) []Delivery {
	out := make([]Delivery, 0, len(t.records))
	for _, r := range t.records {
		d := Delivery{Publication: r.Publication, Subscription: r.Subscription, JobState: r.jobState, LastHistory: r.lastHistory}
		switch {
		case r.run != "":
			d.Status, d.Run = deliveryConfirmed, r.run
		case r.unlisted != "":
			d.Status, d.Detail = deliveryUnconfirmed, r.unlisted
		case notAwaited:
			d.Status = deliveryNotAwaited
		default:
			d.Status, d.Detail = deliveryUnconfirmed, r.reason()
		}
		out = append(out, d)
	}
	return out
}

// reason is why a record is not confirmed.
func (r *record) reason() string {
	switch {
	case r.unlisted != "":
		return r.unlisted
	case r.RunningAtT:
		return "a snapshot run was in progress at T and the record was not retaken"
	case r.Folder == "":
		return fmt.Sprintf("no snapshot folder of %s was listed", r.Publication)
	case len(r.agents) == 0:
		return "no distribution agent row of the subscription"
	case r.Concurrent && !r.concurrentOK:
		return "its MSsubscriptions rows do not all read status 2"
	}
	return "no Delivered snapshot line of a new run"
}

// describe reads, for every record not confirmed, the state of its agent
// job and the comments of its agents' last history row (R53's unconfirmed
// line), at the end of the run. A read that fails leaves the state
// unknown and the history empty: the line is a report, not a decision.
func (t *tracker) describe(ctx context.Context, s *session, p *plan.Plan) {
	var due []*record
	for _, r := range t.records {
		if r.run == "" {
			r.jobState = "unknown"
			due = append(due, r)
		}
	}
	if len(due) == 0 {
		return
	}
	servers, err := t.serversTable(ctx, s, p)
	if err != nil {
		return
	}
	conn, err := s.conn(ctx, t.distributor)
	if err != nil {
		return
	}
	for _, r := range due {
		if r.agents == nil {
			sub, subDB := splitKey(r.Subscription)
			if ids, err := t.agentRows(ctx, conn, p, servers, r.Publication, sub, subDB); err == nil {
				r.agents = ids
			}
		}
		var latest []byte
		states := map[string]bool{}
		for _, a := range r.agents {
			var ts []byte
			var comments string
			if err := conn.QueryRowContext(ctx, distQuery(qLastHistory, p.DistributionDB, ""), a).Scan(&ts, &comments); err == nil {
				if latest == nil || bytes.Compare(ts, latest) > 0 {
					latest, r.lastHistory = ts, comments
				}
			}
			var st string
			if err := conn.QueryRowContext(ctx, distQuery(qAgentJobState, p.DistributionDB, ""), a).Scan(&st); err == nil {
				states[st] = true
			}
		}
		switch {
		case states["running"]:
			r.jobState = "running"
		case states["idle"]:
			r.jobState = "idle"
		default:
			// A pull agent's job is at its subscriber, where the distributor's
			// msdb does not have it: read it there, through the lookup of the
			// plan's job_start of that agent (Task 11 fix round 1).
			if op, ok := pullStartFor(p, r.Publication, r.Subscription); ok {
				if c, err := s.conn(ctx, op.Server); err == nil {
					var idle int
					if c.QueryRowContext(ctx, idleQuery(op.Call.Prologue)).Scan(&idle) == nil {
						r.jobState = map[int]string{0: "running", 1: "idle"}[idle]
					}
				}
			}
		}
	}
}

// pullStartFor is the plan's job_start of the pull agent of a
// subscription, whose prologue finds the job at the subscriber.
func pullStartFor(p *plan.Plan, publication, subscription string) (plan.Operation, bool) {
	for _, op := range p.Operations {
		if op.Kind == "job_start" && strings.HasSuffix(op.Path, ".pull_agent") && op.Call.Prologue != "" &&
			strings.EqualFold(firstString(op.Affects.Publications), publication) &&
			hasFold(op.Affects.Subscriptions, subscription) {
			return op, true
		}
	}
	return plan.Operation{}, false
}
