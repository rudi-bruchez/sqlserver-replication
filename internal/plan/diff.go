package plan

import (
	"fmt"
	"reflect"
	"sort"
	"strconv"
	"strings"

	"github.com/rudi-bruchez/sqlserver-replication/internal/decode"
	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/normalize"
	"github.com/rudi-bruchez/sqlserver-replication/internal/state"
)

// Change is one property whose desired value differs from the current one.
type Change struct {
	// Path is the model path of the property:
	// publications[P].retention_hours. Pattern is its pattern, the key of the
	// cost table: publications[*].retention_hours. For a key of a map
	// (agent_profiles[*].parameters, distributor.properties) Path names the
	// key, parameters[-PollingInterval], and Pattern is the map's pattern,
	// without it, since the cost table is keyed by the map.
	Path, Pattern string
	// Before and After are the model values, as the export writes them; nil
	// is absent.
	Before, After *string
}

// diffObject compares the scalar properties of two objects of one type, by
// YAML tag, pointers and the non-pointer fields named in R-folds alike, and
// skips the paths skip returns true for.
//
// desired and current are pointers to (or values of) the same model type;
// current may be a nil pointer, every current value then being absent.
// Nested objects are walked; lists of objects (publications, articles,
// subscriptions, shared agents, profiles) are not, since they are matched
// first (matchPublications and its siblings) and compared pair by pair.
//
// A nil desired property or object is not compared. Normalization leaves
// nil only what is kept current, what it does not fill (instance-dependent
// values, an omitted pull agent distributor, a generated command procedure,
// an omitted profile, R41) and what means "none" (a filter, a generated
// synchronization view, a pull agent of a push subscription): the strategies
// judge the last ones themselves (R31, Tasks 11 to 14).
//
// The non-pointer fields are compared explicitly: a schedule's fields (R22,
// R37), columns (R30) and a subscription's articles as sets where nil and
// empty are equal, a filter's clause, a command as one value (its mode only
// when the desired procedure is generated, nil), an object name as one
// value.
func diffObject(path string, desired, current any, skip func(path string) bool) []Change {
	return diffIn("", path, desired, current, skip)
}

// diffIn is diffObject for an object of a publication of type pubType, which
// the defaults of an omitted schedule depend on; "" when the caller does not
// know it (diffObject on a Publication reads it from the desired one).
func diffIn(pubType, path string, desired, current any, skip func(path string) bool) []Change {
	if skip == nil {
		skip = func(string) bool { return false }
	}
	w := &walker{skip: skip, pubType: pubType}
	d, c := indirect(reflect.ValueOf(desired)), indirect(reflect.ValueOf(current))
	if !d.IsValid() {
		return nil
	}
	w.walkStruct(path, d, c)
	return w.out
}

type walker struct {
	skip    func(string) bool
	pubType string
	out     []Change
}

// keyFields are the fields that match an object with its current one (R7):
// equal by construction for an exact match, equal without regard to case
// for a folded one, so never compared (a case difference is not a change).
var keyFields = map[reflect.Type]map[string]bool{
	reflect.TypeFor[model.Publication]():             {"name": true},
	reflect.TypeFor[model.Article]():                 {"name": true},
	reflect.TypeFor[model.Subscription]():            {"subscriber": true, "database": true},
	reflect.TypeFor[model.SharedDistributionAgent](): {"subscriber": true, "database": true},
	reflect.TypeFor[model.SharedPullAgent]():         {"subscriber": true, "database": true},
	reflect.TypeFor[model.AgentProfile]():            {"name": true, "agent_type": true},
}

// foldedPatterns are the properties compared without regard to case: the
// server names (CLAUDE.md: they differ in case between tables) and the SQL
// identifiers of an article, compared as the lab collation does (column
// names, a subscription's article names, the article source).
var foldedPatterns = map[string]bool{
	"publisher.server":   true,
	"distributor.server": true,
	"publications[*].subscriptions[*].pull_agent.distributor": true,
	"publisher.shared_pull_agents[*].distributor":             true,
	"publications[*].articles[*].source":                      true,
	"publications[*].articles[*].columns":                     true,
	"publications[*].subscriptions[*].articles":               true,
}

// profileParameters is the map whose keys are compared without regard to
// case (not measured: the cheaper error is a missed rename).
const profileParameters = "agent_profiles[*].parameters"

var (
	scheduleListType = reflect.TypeFor[[]model.Schedule]()
	findingListType  = reflect.TypeFor[[]model.Finding]()
	commandModelType = reflect.TypeFor[model.Command]()
	objectNameType   = reflect.TypeFor[model.ObjectName]()
	publicationType  = reflect.TypeFor[model.Publication]()
)

func (w *walker) add(path, pattern string, before, after *string) {
	w.out = append(w.out, Change{Path: path, Pattern: pattern, Before: before, After: after})
}

// walkStruct compares the fields of d with those of c (invalid when the
// current object is absent).
func (w *walker) walkStruct(path string, d, c reflect.Value) {
	if d.Type() == publicationType {
		if t := d.FieldByName("Type"); !t.IsNil() {
			w.pubType = t.Elem().String()
		}
	}
	t := d.Type()
	keys := keyFields[t]
	for i := range t.NumField() {
		f := t.Field(i)
		tag, ok := f.Tag.Lookup("yaml")
		if !f.IsExported() || !ok || f.Type == findingListType {
			continue
		}
		key, opts, _ := strings.Cut(tag, ",")
		if keys[key] {
			continue // a match key (R7)
		}
		var cf reflect.Value
		if c.IsValid() {
			cf = c.Field(i)
		}
		if strings.Contains(","+opts+",", ",inline,") {
			w.walkStruct(path, d.Field(i), cf)
			continue
		}
		if key == "" {
			key = strings.ToLower(f.Name)
		}
		w.field(model.Join(path, key), d.Field(i), cf)
	}
}

// field compares one field: d is the desired field, c the current one or
// the invalid Value.
func (w *walker) field(path string, d, c reflect.Value) {
	pattern := model.Pattern(path)
	if notCompared(pattern) || w.skip(path) {
		return
	}
	if d.Type() == reflect.PointerTo(scheduleListType) {
		w.schedules(path, d, c)
		return
	}
	dv, cv := indirect(d), indirect(c)
	if !dv.IsValid() {
		return // nil desired: not compared
	}
	switch {
	case dv.Type() == commandModelType:
		w.command(path, pattern, dv, cv)
		return
	case dv.Type() == objectNameType:
		w.scalar(path, pattern, objectName(dv), valueOr(cv, objectName))
		return
	}
	switch dv.Kind() {
	case reflect.Struct:
		w.walkStruct(path, dv, cv)
	case reflect.Slice:
		if dv.Type().Elem().Kind() == reflect.Struct {
			return // matched and compared by the strategies
		}
		if d.Kind() == reflect.Pointer {
			// schema_options: an ordered list, canonical after
			// normalization and in the export.
			w.scalar(path, pattern, listString(dv), valueOr(cv, listString))
			return
		}
		// columns, a subscription's articles: sets, nil and empty equal
		// (R30).
		w.scalar(path, pattern, setString(dv), valueOr(cv, setString))
	case reflect.Map:
		w.mapKeys(path, pattern, dv, cv)
	default:
		w.scalar(path, pattern, scalarString(dv), valueOr(cv, scalarString))
	}
}

func valueOr(v reflect.Value, f func(reflect.Value) string) *string {
	if !v.IsValid() {
		return nil
	}
	s := f(v)
	return &s
}

func (w *walker) scalar(path, pattern string, after string, before *string) {
	if before != nil && (*before == after || foldedPatterns[pattern] && strings.EqualFold(*before, after)) {
		return
	}
	w.add(path, pattern, before, &after)
}

func scalarString(v reflect.Value) string {
	switch v.Kind() {
	case reflect.String:
		return v.String()
	case reflect.Bool:
		return strconv.FormatBool(v.Bool())
	case reflect.Int, reflect.Int64, reflect.Int32:
		return strconv.FormatInt(v.Int(), 10)
	}
	panic("plan: no comparison for " + v.Type().String())
}

func objectName(v reflect.Value) string {
	n := v.Interface().(model.ObjectName)
	return quoteName(n.Schema) + "." + quoteName(n.Name)
}

func listString(v reflect.Value) string {
	xs := make([]string, v.Len())
	for i := range xs {
		xs[i] = v.Index(i).String()
	}
	return "[" + strings.Join(xs, ", ") + "]"
}

// setString writes a set in an order that ignores case, so that two sets
// equal without regard to case give strings equal without regard to case.
func setString(v reflect.Value) string {
	xs := make([]string, v.Len())
	for i := range xs {
		xs[i] = v.Index(i).String()
	}
	sort.Slice(xs, func(i, j int) bool {
		a, b := strings.ToLower(xs[i]), strings.ToLower(xs[j])
		if a != b {
			return a < b
		}
		return xs[i] < xs[j]
	})
	return "[" + strings.Join(xs, ", ") + "]"
}

// command compares a command as one value (the cost table's
// commands.insert): mode and procedure, the procedure name without regard
// to case (a SQL identifier), or the mode alone when the desired procedure
// is nil, generated by the server (normalization, rule 6).
func (w *walker) command(path, pattern string, dv, cv reflect.Value) {
	d := dv.Interface().(model.Command)
	after := commandString(d)
	var before *string
	if cv.IsValid() {
		c := cv.Interface().(model.Command)
		if d.Procedure == nil && strings.EqualFold(c.Mode, d.Mode) {
			return
		}
		s := commandString(c)
		if strings.EqualFold(s, after) {
			return
		}
		before = &s
	}
	w.scalar(path, pattern, after, before)
}

func commandString(c model.Command) string {
	if c.Procedure == nil {
		return c.Mode
	}
	return decode.Command{Mode: c.Mode, Schema: c.Procedure.Schema, Procedure: c.Procedure.Name}.String()
}

// mapKeys compares a map key by key, a key only in the current map giving a
// change to absent; Pattern is the map's (see Change). A profile's
// parameter names are compared without regard to case (normalization
// refuses two that differ only in case); the path names the current key
// when there is one, as for a matched pair.
func (w *walker) mapKeys(path, pattern string, dv, cv reflect.Value) {
	fold := func(k string) string { return k }
	if pattern == profileParameters {
		fold = strings.ToLower
	}
	type entry struct {
		key           string
		before, after *string
	}
	byKey := map[string]*entry{}
	get := func(k string) *entry {
		e := byKey[fold(k)]
		if e == nil {
			e = &entry{key: k}
			byKey[fold(k)] = e
		}
		return e
	}
	// Keys in sorted order, so that two current names differing only in
	// case (normalization refuses them only on the desired side) give the
	// same result at every run: the first in sorted order wins, an exact
	// match of the desired name before it.
	ordered := func(m reflect.Value, prefer map[string]bool) []string {
		var ks []string
		for _, k := range m.MapKeys() {
			ks = append(ks, k.String())
		}
		sort.Slice(ks, func(i, j int) bool {
			if prefer[ks[i]] != prefer[ks[j]] {
				return prefer[ks[i]]
			}
			return ks[i] < ks[j]
		})
		return ks
	}
	desKeys := map[string]bool{}
	for _, k := range dv.MapKeys() {
		desKeys[k.String()] = true
	}
	if cv.IsValid() {
		for _, k := range ordered(cv, desKeys) {
			if e := get(k); e.before == nil {
				e.before = model.Ptr(cv.MapIndex(reflect.ValueOf(k)).String())
			}
		}
	}
	for _, k := range ordered(dv, nil) {
		if e := get(k); e.after == nil {
			e.after = model.Ptr(dv.MapIndex(reflect.ValueOf(k)).String())
		}
	}
	folded := map[string]bool{}
	for k := range byKey {
		folded[k] = true
	}
	for _, k := range sortedKeys(folded) {
		e := byKey[k]
		kp := path + model.Element(e.key)
		if w.skip(kp) {
			continue
		}
		if e.before != nil && e.after != nil && *e.before == *e.after {
			continue
		}
		w.add(kp, pattern, e.before, e.after)
	}
}

// schedules compares an agent's schedules (R22). Schedules are compared
// without their name, which replication generates, and without enabled
// (R38). An omitted (nil) list is the procedure's schedule, compared on
// frequency, interval, subday and subday_interval when the defaults table
// has it for the agent, and not compared otherwise. A declared schedule is
// compared on every other field, start_date and start_time only when not
// zero (R37). Lists of different lengths are one change of the list. A
// schedule field's path names the current schedule.
func (w *walker) schedules(path string, d, c reflect.Value) {
	cv := indirect(c)
	if !cv.IsValid() {
		return // no current list to compare with
	}
	cur := cv.Interface().([]model.Schedule)
	if d.IsNil() {
		def, ok := defaultSchedule(model.Pattern(path), w.pubType)
		switch {
		case !ok:
			return // no measured default for this agent: not compared
		case len(cur) != 1:
			w.add(path, model.Pattern(path), model.Ptr(scheduleNames(cur)), model.Ptr("[default]"))
		default:
			w.scheduleFields(path+model.Element(cur[0].Name), def, cur[0], frequencyFields)
		}
		return
	}
	des := *d.Interface().(*[]model.Schedule)
	if len(des) != 1 {
		return // refused before any comparison (scheduleRefusals, R22)
	}
	if len(des) != len(cur) {
		w.add(path, model.Pattern(path), model.Ptr(scheduleNames(cur)), model.Ptr(scheduleNames(des)))
		return
	}
	for i := range des {
		// The current schedule's name, as pair.path uses the current key:
		// the name an unreadable finding writes (R26).
		w.scheduleFields(path+model.Element(cur[i].Name), des[i], cur[i], declaredFields)
	}
}

func scheduleNames(ss []model.Schedule) string {
	xs := make([]string, len(ss))
	for i, s := range ss {
		xs[i] = s.Name
	}
	return "[" + strings.Join(xs, ", ") + "]"
}

// The schedule fields compared: an omitted schedule's frequency fields
// (R22), a declared schedule's every field but name and enabled.
var (
	frequencyFields = []string{"frequency", "interval", "subday", "subday_interval"}
	declaredFields  = []string{"frequency", "interval", "subday", "subday_interval", "relative_interval",
		"recurrence_factor", "start_date", "end_date", "start_time", "end_time"}
)

func (w *walker) scheduleFields(path string, d, c model.Schedule, keys []string) {
	dv, cv := reflect.ValueOf(d), reflect.ValueOf(c)
	for _, key := range keys {
		fp := model.Join(path, key)
		if notCompared(model.Pattern(fp)) || w.skip(fp) {
			continue
		}
		df, cf := scheduleField(dv, key), scheduleField(cv, key)
		if (key == "start_date" || key == "start_time") && df.Int() == 0 {
			continue // R37: an omitted start keeps the current one
		}
		w.scalar(fp, model.Pattern(fp), scalarString(df), model.Ptr(scalarString(cf)))
	}
}

func scheduleField(v reflect.Value, key string) reflect.Value {
	t := v.Type()
	for i := range t.NumField() {
		k, _, _ := strings.Cut(t.Field(i).Tag.Get("yaml"), ",")
		if k == key {
			return v.Field(i)
		}
	}
	panic("plan: no schedule field " + key)
}

// scheduleObjects are the objects of the defaults table whose entries may
// hold an agent's schedule, deepest base first.
var scheduleObjects = []string{
	"push_agent", "shared_push_agent", "pull_agent", "snapshot_agent", "log_reader_agent",
	"push_subscription", "pull_subscription", "subscriber_pull_subscription",
}

// defaultSchedule is the schedule the creation procedure of the agent at
// the path pattern agent (its schedules field) stores, from the defaults
// table: the frequency fields of normalize.Lookup for the object whose base
// the pattern is under. pubType "" takes an entry measured for any type, or
// the one both types agree on; a context without the frequency has no
// default.
func defaultSchedule(schedules, pubType string) (model.Schedule, bool) {
	try := func(pt string) (model.Schedule, bool) {
		for _, o := range scheduleObjects {
			base, ok := normalize.ObjectBase(o)
			if !ok {
				continue
			}
			rel, ok := strings.CutPrefix(schedules+"[*].", base+".")
			if !ok {
				continue
			}
			var s model.Schedule
			ctx := normalize.Context{Object: o, PubType: pt}
			freq, ok := normalize.Lookup(ctx, rel+"frequency")
			if !ok {
				continue
			}
			s.Frequency = freq.Value
			if d, ok := normalize.Lookup(ctx, rel+"subday"); ok {
				s.Subday = d.Value
			}
			for _, x := range []struct {
				key string
				dst *int
			}{{"interval", &s.Interval}, {"subday_interval", &s.SubdayInterval}} {
				if d, ok := normalize.Lookup(ctx, rel+x.key); ok {
					n, err := strconv.Atoi(d.Value)
					if err != nil {
						return model.Schedule{}, false
					}
					*x.dst = n
				}
			}
			return s, true
		}
		return model.Schedule{}, false
	}
	if pubType != "" {
		return try(pubType)
	}
	if s, ok := try(""); ok {
		return s, true
	}
	tr, ok1 := try("transactional")
	sn, ok2 := try("snapshot")
	if ok1 && ok2 && tr == sn {
		return tr, true
	}
	return model.Schedule{}, false
}

// creationOnly are the path patterns of the creation-only parameters
// (model.Parameters): passed at creation, never read, so never compared.
var creationOnly = func() []string {
	var out []string
	for _, m := range model.Parameters {
		if m.Kind == model.ParamCreationOnly {
			out = append(out, m.Paths...)
		}
	}
	return out
}()

// notCompared tells whether the property at a path pattern is left out of
// the comparison (spec "What is not compared"): the generated names and the
// job step (job_name, run_as, command, R32, R41), a schedule's name and
// enabled (R22, R38), the initialization of an existing subscription (spec;
// R21's note is the subscription strategy's), the findings, every secret
// (spec "Secrets": plan never plans a password change, rotation is plan
// 4's), and the creation-only parameters. The derived status bits (0x8 and
// 0x20 with timestamp_as_timestamp, the active bit) are not in the model;
// the derived insert_column_names is set to the current value by
// normalization (rule 9).
func notCompared(pattern string) bool {
	if pattern == "findings" || strings.HasPrefix(pattern, "findings.") || strings.HasPrefix(pattern, "findings[") {
		return true
	}
	last := pattern
	if i := strings.LastIndex(pattern, "."); i >= 0 {
		last = pattern[i+1:]
	}
	switch last {
	case "job_name", "run_as", "command":
		return true
	case "name", "enabled":
		if strings.HasSuffix(pattern, ".schedules[*]."+last) {
			return true
		}
	}
	if strings.HasSuffix(last, "_secret") {
		return true
	}
	if pattern == "publications[*].subscriptions[*].initialization" {
		return true
	}
	for _, p := range creationOnly {
		if pattern == p || strings.HasPrefix(pattern, p+".") {
			return true
		}
	}
	return false
}

// refusedChanges are the compared changes the planner refuses with a
// reason of their own, checked before "not measured": the server accepts
// the call, the refusal is the planner's.
//
// A login change needs its password (R16): every connection login, the FTP
// login, and an agent's job_login. unmeasured is reached only for a change
// without a cost entry, so the job_login entries the table refuses with
// 14529 (log reader, snapshot, push and pull agents of a transactional
// publication) keep their own refusal; the shared agents' job_login, which
// has none, gets this one.
var refusedChanges = []struct {
	pattern string // the pattern, or with a leading "." a suffix of it
	reason  string
}{
	{".connection.login", loginReason},             // any agent's connection
	{".distributor_connection.login", loginReason}, // snapshot and pull agents
	{"distributor.publisher_connection.login", loginReason},
	{"publications[*].snapshot.ftp.login", loginReason},
	{".job_login", loginReason},
}

const loginReason = "a login change needs its password, which plan does not compare (R16); plan 4"

func refusedChange(pattern string) (string, bool) {
	for _, r := range refusedChanges {
		if pattern == r.pattern || strings.HasPrefix(r.pattern, ".") && strings.HasSuffix(pattern, r.pattern) {
			return r.reason, true
		}
	}
	return "", false
}

// keyed is a model object of a list, named in a path by its key.
type keyed interface{ Key() string }

// pair is a desired object and the current object it matches.
type pair[T keyed] struct{ Des, Cur *T }

// path is the path of the pair's object in the list at list
// (publications[P].subscriptions): the paths of a matched pair are built
// from the current key, the one the reader writes in its findings, so that
// an unreadable finding skips the pair whatever the case of the desired
// key (R26). Every strategy diffs a pair at this path.
func (p pair[T]) path(list string) string { return list + model.Element((*p.Cur).Key()) }

// match pairs the objects of two lists by key, keys compared by eq; the
// pairs and the desired-only objects are sorted by the desired key, the
// current-only ones by theirs.
func match[T keyed](des, cur []T, key func(*T) string, eq func(a, b *T) bool) (pairs []pair[T], desOnly, curOnly []*T) {
	used := make([]bool, len(cur))
	for i := range des {
		found := false
		for j := range cur {
			if !used[j] && eq(&des[i], &cur[j]) {
				pairs = append(pairs, pair[T]{&des[i], &cur[j]})
				used[j], found = true, true
				break
			}
		}
		if !found {
			desOnly = append(desOnly, &des[i])
		}
	}
	for j := range cur {
		if !used[j] {
			curOnly = append(curOnly, &cur[j])
		}
	}
	sort.SliceStable(pairs, func(i, j int) bool { return key(pairs[i].Des) < key(pairs[j].Des) })
	sort.SliceStable(desOnly, func(i, j int) bool { return key(desOnly[i]) < key(desOnly[j]) })
	sort.SliceStable(curOnly, func(i, j int) bool { return key(curOnly[i]) < key(curOnly[j]) })
	return pairs, desOnly, curOnly
}

// matchPublications matches publications by exact name (R7).
func matchPublications(des, cur []model.Publication) ([]pair[model.Publication], []*model.Publication, []*model.Publication) {
	return match(des, cur, func(p *model.Publication) string { return p.Name },
		func(a, b *model.Publication) bool { return a.Name == b.Name })
}

// matchArticles matches articles by exact name (R7).
func matchArticles(des, cur []model.Article) ([]pair[model.Article], []*model.Article, []*model.Article) {
	return match(des, cur, func(a *model.Article) string { return a.Name },
		func(a, b *model.Article) bool { return a.Name == b.Name })
}

// matchFold matches objects keyed by a subscriber and a database, both
// compared without regard to case (R7): subscriptions, shared agents.
func matchFold[T keyed](des, cur []T, key func(*T) (subscriber, database string)) ([]pair[T], []*T, []*T) {
	return match(des, cur,
		func(x *T) string { s, d := key(x); return strings.ToLower(s + "/" + d) },
		func(a, b *T) bool {
			as, ad := key(a)
			bs, bd := key(b)
			return strings.EqualFold(as, bs) && strings.EqualFold(ad, bd)
		})
}

// matchSubscriptions matches subscriptions by subscriber and database,
// without regard to case (R7, Review Focus 2).
func matchSubscriptions(des, cur []model.Subscription) ([]pair[model.Subscription], []*model.Subscription, []*model.Subscription) {
	return matchFold(des, cur, func(s *model.Subscription) (string, string) { return s.Subscriber, s.Database })
}

// matchProfiles matches profiles by agent type and by name without regard
// to case (R6, R7).
func matchProfiles(des, cur []model.AgentProfile) ([]pair[model.AgentProfile], []*model.AgentProfile, []*model.AgentProfile) {
	return match(des, cur, func(p *model.AgentProfile) string { return p.AgentType + "/" + strings.ToLower(p.Name) },
		func(a, b *model.AgentProfile) bool {
			return a.AgentType == b.AgentType && strings.EqualFold(a.Name, b.Name)
		})
}

// unreadable is the skip function of a current configuration's unreadable
// findings (R26): a finding's path and everything under it.
func unreadable(cur *model.Config) func(path string) bool {
	var paths []string
	if cur != nil {
		for _, f := range cur.Findings {
			if f.Kind == model.FindingUnreadable {
				paths = append(paths, f.Path)
			}
		}
	}
	return func(path string) bool {
		for _, p := range paths {
			if path == p || strings.HasPrefix(path, p+".") || strings.HasPrefix(path, p+"[") {
				return true
			}
		}
		return false
	}
}

// foldColumns writes nil for an article's columns when they are empty or,
// as a set, the full column list of its source table read by the checks
// (R30). When the table's columns were not read, the lists are compared as
// given, nil and empty still equal.
func foldColumns(c *model.Config, checks *state.Checks) {
	for i := range c.Publications {
		for j := range c.Publications[i].Articles {
			a := &c.Publications[i].Articles[j]
			if len(a.Columns) == 0 || fullColumns(a, checks) {
				a.Columns = nil
			}
		}
	}
}

func fullColumns(a *model.Article, checks *state.Checks) bool {
	if checks == nil {
		return false
	}
	for _, t := range checks.Tables {
		if !strings.EqualFold(t.Schema, a.Source.Schema) || !strings.EqualFold(t.Name, a.Source.Name) || len(t.Columns) == 0 {
			continue
		}
		have := map[string]bool{}
		for _, col := range a.Columns {
			have[strings.ToLower(col)] = true
		}
		if len(have) != len(t.Columns) {
			return false
		}
		for _, col := range t.Columns {
			if !have[strings.ToLower(col)] {
				return false
			}
		}
		return true
	}
	return false
}

// scheduleRefusals refuses, in the desired configuration, every agent with
// more than one schedule and every empty schedules list (R22), before any
// comparison or cost lookup: the planner changes one schedule per agent,
// and an empty list neither keeps the procedure's schedule (omit the list)
// nor declares one.
func scheduleRefusals(des *model.Config) []Refusal {
	var out []Refusal
	var walk func(path string, v reflect.Value)
	walk = func(path string, v reflect.Value) {
		switch v.Kind() {
		case reflect.Pointer:
			if v.IsNil() {
				return
			}
			if v.Type() == reflect.PointerTo(scheduleListType) {
				switch n := v.Elem().Len(); {
				case n == 0:
					out = append(out, Refusal{Path: path, Reason: "an empty schedules list is refused (R22): omit schedules for the procedure's schedule, or declare one"})
				case n > 1:
					out = append(out, Refusal{Path: path, Reason: fmt.Sprintf("an agent with more than one schedule is refused (R22): %d schedules declared", n)})
				}
				return
			}
			walk(path, v.Elem())
		case reflect.Struct:
			t := v.Type()
			for i := range t.NumField() {
				f := t.Field(i)
				tag, ok := f.Tag.Lookup("yaml")
				if !f.IsExported() || !ok || f.Type == findingListType {
					continue
				}
				key, opts, _ := strings.Cut(tag, ",")
				if strings.Contains(","+opts+",", ",inline,") {
					walk(path, v.Field(i))
					continue
				}
				walk(model.Join(path, key), v.Field(i))
			}
		case reflect.Slice:
			if v.Type().Elem().Kind() != reflect.Struct || v.Type() == scheduleListType {
				return
			}
			for i := range v.Len() {
				e := v.Index(i)
				walk(path+model.Element(e.Addr().Interface().(keyed).Key()), e)
			}
		}
	}
	walk("", reflect.ValueOf(des))
	return out
}
