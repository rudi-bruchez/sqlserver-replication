package normalize

import (
	"fmt"
	"reflect"
	"sort"
	"strconv"
	"strings"

	"github.com/rudi-bruchez/sqlserver-replication/internal/decode"
	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
)

// Refusal is a property of the desired file the plan cannot act on.
type Refusal struct {
	Path   string `json:"path"`
	Reason string `json:"reason"`
}

// Normalize returns a deep copy of desired in which every omitted property
// holds the value it means, and the refusals. current may be nil.
//
// The rules run in a fixed order (plan 3, Task 6): enumerations, required
// properties, names, prerequisites, defaults, the properties kept current,
// conflicts, the identity schema option, the derived insert_column_names.
// A publication with a refused enumeration skips the rules after the
// names: the contexts its defaults depend on cannot be read. The other
// publications are normalized and refused as usual (R3: every refusal at
// once).
func Normalize(desired, current *model.Config) (*model.Config, []Refusal) {
	return normalize(Defaults, desired, current)
}

func normalize(table []Default, desired, current *model.Config) (*model.Config, []Refusal) {
	out := clone(desired)
	out.Findings = nil
	n := &normalizer{current: current, table: table, syncDep: syncDependent(table)}
	n.enumerations(out)
	unread := n.refusedPublications(out)
	n.required(out)
	n.names(out)

	all := out.Publications
	if len(unread) > 0 {
		out.Publications = nil
		for _, p := range all {
			if !unread[p.Name] {
				out.Publications = append(out.Publications, p)
			}
		}
	}
	n.prerequisites(out)
	n.defaults(out)
	n.keepCurrent(out)
	n.passwords(out)
	n.conflicts(out)
	n.identityOption(out)
	n.timestampColumns(out)
	if len(unread) > 0 {
		done := out.Publications
		out.Publications = make([]model.Publication, 0, len(all))
		for _, p := range all {
			if unread[p.Name] {
				out.Publications = append(out.Publications, p)
			} else {
				out.Publications, done = append(out.Publications, done[0]), done[1:]
			}
		}
	}
	return out, n.refusals
}

type normalizer struct {
	current  *model.Config
	table    []Default
	syncDep  map[string]bool // syncDependent(table)
	refusals []Refusal
}

// refusedPublications names the publications a refusal so far is under.
func (n *normalizer) refusedPublications(c *model.Config) map[string]bool {
	out := map[string]bool{}
	for i := range c.Publications {
		pp := pubPath(&c.Publications[i])
		for _, r := range n.refusals {
			if r.Path == pp || strings.HasPrefix(r.Path, pp+".") {
				out[c.Publications[i].Name] = true
			}
		}
	}
	return out
}

func (n *normalizer) refuse(path, format string, args ...any) {
	n.refusals = append(n.refusals, Refusal{Path: path, Reason: fmt.Sprintf(format, args...)})
}

// clone deep-copies a configuration.
func clone(c *model.Config) *model.Config {
	out := new(model.Config)
	copyValue(reflect.ValueOf(out).Elem(), reflect.ValueOf(c).Elem())
	return out
}

func copyValue(dst, src reflect.Value) {
	switch src.Kind() {
	case reflect.Pointer:
		if src.IsNil() {
			return
		}
		v := reflect.New(src.Type().Elem())
		copyValue(v.Elem(), src.Elem())
		dst.Set(v)
	case reflect.Struct:
		for i := range src.NumField() {
			copyValue(dst.Field(i), src.Field(i))
		}
	case reflect.Slice:
		if src.IsNil() {
			return
		}
		s := reflect.MakeSlice(src.Type(), src.Len(), src.Len())
		for i := range src.Len() {
			copyValue(s.Index(i), src.Index(i))
		}
		dst.Set(s)
	case reflect.Map:
		if src.IsNil() {
			return
		}
		m := reflect.MakeMapWithSize(src.Type(), src.Len())
		for it := src.MapRange(); it.Next(); {
			v := reflect.New(src.Type().Elem()).Elem()
			copyValue(v, it.Value())
			m.SetMapIndex(it.Key(), v)
		}
		dst.Set(m)
	default:
		dst.Set(src)
	}
}

func pubPath(p *model.Publication) string { return "publications" + model.Element(p.Key()) }

func artPath(p *model.Publication, a *model.Article) string {
	return pubPath(p) + ".articles" + model.Element(a.Key())
}

func subPath(p *model.Publication, s *model.Subscription) string {
	return pubPath(p) + ".subscriptions" + model.Element(s.Key())
}

func isTrue(b *bool) bool  { return b != nil && *b }
func isFalse(b *bool) bool { return b != nil && !*b }

func deref(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

// agentRef is one agent of a configuration, with the key that matches it
// with the same agent of another configuration: subscriber and database
// without regard to case (R7).
type agentRef struct {
	path     string
	key      string
	agent    *model.Agent
	pull     *model.PullAgent
	snapshot bool
}

func agents(c *model.Config) []agentRef {
	if c == nil {
		return nil
	}
	var out []agentRef
	if a := c.Publisher.LogReaderAgent; a != nil {
		out = append(out, agentRef{path: "publisher.log_reader_agent", key: "log_reader", agent: a})
	}
	for i := range c.Publisher.SharedDistributionAgents {
		s := &c.Publisher.SharedDistributionAgents[i]
		out = append(out, agentRef{path: "publisher.shared_distribution_agents" + model.Element(s.Key()) + ".distribution_agent",
			key: "shared_distribution/" + strings.ToUpper(s.Key()), agent: &s.DistributionAgent.Agent})
	}
	for i := range c.Publisher.SharedPullAgents {
		s := &c.Publisher.SharedPullAgents[i]
		out = append(out, agentRef{path: "publisher.shared_pull_agents" + model.Element(s.Key()),
			key: "shared_pull/" + strings.ToUpper(s.Key()), agent: &s.PullAgent.Agent, pull: &s.PullAgent})
	}
	for i := range c.Publications {
		p := &c.Publications[i]
		if a := p.SnapshotAgent; a != nil {
			out = append(out, agentRef{path: pubPath(p) + ".snapshot_agent", key: "snapshot/" + p.Name, agent: a, snapshot: true})
		}
		for j := range p.Subscriptions {
			s := &p.Subscriptions[j]
			k := p.Name + "/" + strings.ToUpper(s.Key())
			if a := s.DistributionAgent; a != nil {
				out = append(out, agentRef{path: subPath(p, s) + ".distribution_agent", key: "push/" + k, agent: &a.Agent})
			}
			if a := s.PullAgent; a != nil {
				out = append(out, agentRef{path: subPath(p, s) + ".pull_agent", key: "pull/" + k, agent: &a.Agent, pull: a})
			}
		}
	}
	return out
}

func (n *normalizer) currentAgent(key string) *agentRef {
	for _, r := range agents(n.current) {
		if r.key == key {
			return &r
		}
	}
	return nil
}

func (n *normalizer) currentPub(name string) *model.Publication {
	if n.current == nil {
		return nil
	}
	for i := range n.current.Publications {
		if n.current.Publications[i].Name == name {
			return &n.current.Publications[i]
		}
	}
	return nil
}

func (n *normalizer) currentArticle(pub, name string) *model.Article {
	p := n.currentPub(pub)
	if p == nil {
		return nil
	}
	for i := range p.Articles {
		if p.Articles[i].Name == name {
			return &p.Articles[i]
		}
	}
	return nil
}

// Rule 1: every coded value goes through its decode inverse; an error or an
// unknown(...) value is refused, since the engine cannot create what it
// cannot name. A schema option written as a hexadecimal bit is accepted:
// EncodeSchemaOptions passes it as that bit.
func (n *normalizer) enumerations(c *model.Config) {
	check := func(path string, v *string, inverse func(string) error) {
		if v == nil {
			return
		}
		if err := inverse(*v); err != nil || strings.HasPrefix(*v, "unknown(") {
			n.refuse(path, "unknown value %q", *v)
		}
	}
	code := func(f func(string) (int, error)) func(string) error {
		return func(s string) error { _, err := f(s); return err }
	}
	set := func(names ...string) func(string) error {
		return func(s string) error {
			for _, x := range names {
				if s == x {
					return nil
				}
			}
			return fmt.Errorf("unknown value %q", s)
		}
	}
	connection := func(path string, cn *model.Connection) {
		if cn != nil {
			check(path+".security", cn.Security, code(decode.SecurityModeCode))
		}
	}
	if d := c.Distributor; d != nil {
		connection("distributor.publisher_connection", d.PublisherConnection)
		connection("distributor.creation_connection", d.CreationConnection)
		check("distributor.admin_link_security", d.AdminLinkSecurity, code(decode.SecurityModeCode))
	}
	for _, r := range agents(c) {
		connection(r.path+".connection", r.agent.Connection)
		connection(r.path+".distributor_connection", r.agent.DistributorConnection)
		if r.agent.Schedules == nil {
			continue
		}
		for _, s := range *r.agent.Schedules {
			sp := r.path + ".schedules" + model.Element(s.Key())
			if s.Frequency != "" {
				check(sp+".frequency", &s.Frequency, code(decode.FreqTypeCode))
			}
			if s.Subday != "" {
				check(sp+".subday", &s.Subday, code(decode.FreqSubdayTypeCode))
			}
		}
	}
	for i := range c.Publications {
		p := &c.Publications[i]
		pp := pubPath(p)
		check(pp+".type", p.Type, code(decode.PublicationTypeCode))
		check(pp+".status", p.Status, code(decode.PublicationStatusCode))
		check(pp+".sync_method", p.SyncMethod, code(decode.SyncMethodCode))
		for j := range p.Articles {
			a := &p.Articles[j]
			ap := artPath(p, a)
			check(ap+".type", a.Type, code(decode.ArticleTypeCode))
			check(ap+".pre_creation_cmd", a.PreCreationCmd, code(decode.PreCreationCmdCode))
			check(ap+".identity_range_management", a.IdentityRangeManagement, set("none", "manual", "auto"))
			if a.SchemaOptions != nil {
				before := len(n.refusals)
				for _, o := range *a.SchemaOptions {
					check(ap+".schema_options", &o, func(s string) error {
						_, err := decode.EncodeSchemaOptions([]string{s})
						return err
					})
				}
				// The canonical list, as the export writes it: in bit
				// order, once each, a known bit written in hexadecimal
				// by its name, an unknown one kept in hexadecimal.
				if len(n.refusals) == before {
					v, _ := decode.EncodeSchemaOptions(*a.SchemaOptions)
					names := decode.SchemaOptionNames(v)
					a.SchemaOptions = &names
				}
			}
			if cs := a.Commands; cs != nil {
				for _, x := range []struct {
					key string
					c   *model.Command
				}{{"insert", cs.Insert}, {"update", cs.Update}, {"delete", cs.Delete}} {
					if x.c != nil {
						check(ap+".commands."+x.key+".mode", &x.c.Mode, set("CALL", "SCALL", "MCALL", "XCALL", "SQL", "NONE"))
					}
				}
			}
		}
		for j := range p.Subscriptions {
			s := &p.Subscriptions[j]
			sp := subPath(p, s)
			check(sp+".type", s.Type, code(decode.SubscriptionTypeCode))
			check(sp+".subscriber_type", s.SubscriberType, code(decode.SubscriberTypeCode))
			check(sp+".initialization", s.Initialization, func(v string) error {
				_, _, err := decode.InitializationCode(v)
				return err
			})
		}
	}
	for _, pr := range c.AgentProfiles {
		check("agent_profiles"+model.Element(pr.Key())+".agent_type", &pr.AgentType, code(decode.AgentTypeCode))
	}
}

// Rule 2: the properties with no default (spec "Omitted properties", R38).
func (n *normalizer) required(c *model.Config) {
	const reason = "%s has no default and must be written"
	for i := range c.Publications {
		p := &c.Publications[i]
		if p.Status == nil {
			n.refuse(pubPath(p)+".status", reason, "status")
		}
		for j := range p.Articles {
			a := &p.Articles[j]
			if a.Filter != nil && (a.Filter.Procedure == nil || a.Filter.Procedure.Name == "") {
				n.refuse(artPath(p, a)+".filter.procedure", reason, "filter.procedure")
			}
		}
		for j := range p.Subscriptions {
			s := &p.Subscriptions[j]
			if s.Initialization == nil {
				n.refuse(subPath(p, s)+".initialization", reason, "initialization")
			}
		}
	}
	for _, r := range agents(c) {
		if r.agent.Schedules == nil {
			continue
		}
		for _, s := range *r.agent.Schedules {
			if s.Frequency == "" {
				n.refuse(r.path+".schedules"+model.Element(s.Key())+".frequency", reason, "frequency")
			}
		}
	}
}

// bracketName is the refusal of a publication or article name with a
// bracket.
const bracketName = "%s: names of publications and articles cannot contain [ or ] (15006, measured)"

// Rule 3: names. Two publications whose names are equal without regard to
// case collide in distribution.dbo.MSpublications (R7). A column listed
// twice, names compared without regard to case as the plan compares them,
// is refused, and so are two parameters of a profile whose names differ
// only in case: the plan compares both without regard to case. A command
// procedure, a filter procedure, a synchronization object and an article
// source written without a schema get dbo, the schema sp_addarticle and
// sp_articlefilter store (spec "Names", 11-defaults
// D.sp_addarticle.table.non-dbo-schema.@ins_cmd).
func (n *normalizer) names(c *model.Config) {
	seen := map[string]string{}
	for i := range c.Publications {
		p := &c.Publications[i]
		k := strings.ToUpper(p.Name)
		if first, ok := seen[k]; ok {
			n.refuse(pubPath(p), "publications %q and %q have names equal without regard to case: they collide in distribution.dbo.MSpublications", first, p.Name)
			continue
		}
		seen[k] = p.Name
	}
	// sp_addpublication and sp_addarticle refuse a name with a bracket
	// (sys.sp_MSreplcheck_name, 15006, measured), after the earlier
	// operations of the plan have run: refused here instead.
	for i := range c.Publications {
		p := &c.Publications[i]
		if strings.ContainsAny(p.Name, "[]") {
			n.refuse(pubPath(p), bracketName, p.Name)
		}
		for j := range p.Articles {
			if a := &p.Articles[j]; strings.ContainsAny(a.Name, "[]") {
				n.refuse(artPath(p, a), bracketName, a.Name)
			}
		}
	}
	qualify := func(o *model.ObjectName) {
		if o != nil && o.Schema == "" {
			o.Schema = "dbo"
		}
	}
	for i := range c.Publications {
		p := &c.Publications[i]
		for j := range p.Subscriptions {
			s := &p.Subscriptions[j]
			// Measured by the Task 12 review: [T1,t1,T2,T2] collapsed to
			// N'all', and [T1,t1] gave 14058 on its second call.
			arts, dup := map[string]bool{}, false
			for _, a := range s.Articles {
				if k := strings.ToLower(a); arts[k] {
					n.refuse(subPath(p, s)+".articles", "article %s listed twice", a)
					dup = true
				} else {
					arts[k] = true
				}
			}
			if dup {
				continue
			}
			if s.Articles != nil && (len(s.Articles) == 0 || everyArticle(p, s.Articles)) {
				s.Articles = nil // every article, as the export writes it
			}
		}
		for j := range c.Publications[i].Articles {
			a := &c.Publications[i].Articles[j]
			cols := map[string]bool{}
			for _, col := range a.Columns {
				if k := strings.ToLower(col); cols[k] {
					n.refuse(artPath(p, a)+".columns", "column %q is listed twice (column names are compared without regard to case)", col)
				} else {
					cols[k] = true
				}
			}
			qualify(&a.Source)
			qualify(a.SyncObject)
			if a.SyncObject != nil && a.SyncObject.Schema != "dbo" && (a.Filter != nil || len(a.Columns) > 0) {
				// Measured by the Task 8 review: sp_articleview ignores the
				// schema of @view_name and creates the view in dbo. It is
				// called for an article with a row or a column filter; a
				// view of the user's that sp_addarticle @sync_object and
				// @sync_object_owner name can be in any schema.
				n.refuse(artPath(p, a)+".sync_object", "a synchronization view outside dbo (%s) is not supported: sp_articleview creates its view in dbo whatever the schema of @view_name (measured)", a.SyncObject.Schema)
			}
			if a.Filter != nil {
				qualify(a.Filter.Procedure)
			}
			if cs := a.Commands; cs != nil {
				for _, x := range []*model.Command{cs.Insert, cs.Update, cs.Delete} {
					if x != nil {
						qualify(x.Procedure)
					}
				}
			}
		}
	}
	// Two objects whose keys are equal without regard to case would match
	// one current object (R7); model.Load refuses the duplicate
	// subscriptions and shared agents, a Config built in code does not.
	folded := func(list string, keys []string, what string) {
		seen := map[string]string{}
		for _, k := range keys {
			if first, ok := seen[strings.ToUpper(k)]; ok {
				n.refuse(list+model.Element(k), "%s %q and %q are equal without regard to case, as they are matched (R7)", what, first, k)
				continue
			}
			seen[strings.ToUpper(k)] = k
		}
	}
	var keys []string
	for _, pr := range c.AgentProfiles {
		keys = append(keys, pr.Key())
	}
	folded("agent_profiles", keys, "profiles")
	keys = nil
	for _, a := range c.Publisher.SharedDistributionAgents {
		keys = append(keys, a.Key())
	}
	folded("publisher.shared_distribution_agents", keys, "shared distribution agents")
	keys = nil
	for _, a := range c.Publisher.SharedPullAgents {
		keys = append(keys, a.Key())
	}
	folded("publisher.shared_pull_agents", keys, "shared pull agents")
	for i := range c.Publications {
		p := &c.Publications[i]
		keys = nil
		for _, s := range p.Subscriptions {
			keys = append(keys, s.Key())
		}
		folded(pubPath(p)+".subscriptions", keys, "subscriptions")
	}
	for i := range c.AgentProfiles {
		pr := &c.AgentProfiles[i]
		byName := map[string][]string{}
		for k := range pr.Parameters {
			byName[strings.ToLower(k)] = append(byName[strings.ToLower(k)], k)
		}
		var dups []string
		for _, ks := range byName {
			if len(ks) > 1 {
				sort.Strings(ks)
				dups = append(dups, strings.Join(ks, ", "))
			}
		}
		sort.Strings(dups)
		for _, d := range dups {
			n.refuse("agent_profiles"+model.Element(pr.Key())+".parameters", "parameters %s differ only in case (parameter names are compared without regard to case)", d)
		}
	}
}

// everyArticle: names, as a set, are the publication's article names,
// compared without regard to case as the plan compares a subscription's
// articles.
func everyArticle(p *model.Publication, names []string) bool {
	set := map[string]bool{}
	for _, x := range names {
		set[strings.ToLower(x)] = true
	}
	if len(set) != len(p.Articles) {
		return false
	}
	for _, a := range p.Articles {
		if !set[strings.ToLower(a.Name)] {
			return false
		}
	}
	return true
}

// Rule 4: an omitted prerequisite takes the value the declared property
// requires, before any default (spec "Omitted properties"; plan 2 "Rulings"
// for the partition switch options, 0x60).
func (n *normalizer) prerequisites(c *model.Config) {
	for i := range c.Publications {
		p := &c.Publications[i]
		if isTrue(p.AllowAnonymous) && p.ImmediateSync == nil {
			p.ImmediateSync = model.Ptr(true)
		}
		if isTrue(p.ImmediateSync) && p.IndependentAgent == nil {
			p.IndependentAgent = model.Ptr(true)
		}
		for _, s := range p.Subscriptions {
			if deref(s.Type) == "pull" {
				if p.AllowPull == nil {
					p.AllowPull = model.Ptr(true)
				}
			} else if p.AllowPush == nil {
				p.AllowPush = model.Ptr(true)
			}
		}
		if p.ReplicatePartitionSwitch == nil && p.AllowPartitionSwitch != nil {
			p.ReplicatePartitionSwitch = model.Ptr(*p.AllowPartitionSwitch)
		}
	}
}

// articleKind is the ArticleKind of a defaults context: "table" for the
// logbased family, the type name otherwise.
func articleKind(typ *string) string {
	t := deref(typ)
	if t == "" || strings.HasPrefix(t, "logbased") {
		return "table"
	}
	return t
}

// concurrentOnSnapshot: a snapshot publication cannot be created with a
// concurrent method (22547); rule 7 refuses it, and rule 5 looks up no
// default for its articles, which no row could measure.
func concurrentOnSnapshot(p *model.Publication) bool {
	m := deref(p.SyncMethod)
	return deref(p.Type) == "snapshot" && (m == "concurrent" || m == "concurrent_c")
}

// objectOrder lists the objects of the defaults table, deepest base first,
// so that a property is looked up first in the object it belongs to.
var objectOrder = func() []string {
	var out []string
	for o := range objectBases {
		out = append(out, o)
	}
	sort.Slice(out, func(i, j int) bool {
		if li, lj := len(objectBases[out[i]]), len(objectBases[out[j]]); li != lj {
			return li > lj
		}
		return out[i] < out[j]
	})
	return out
}()

// frame is what the defaults of a property depend on: the enclosing
// publication and article, already normalized.
type frame struct {
	pub *model.Publication
	art *model.Article
	sub *model.Subscription
}

// applies tells whether the entries of object o may fill the property rel
// of its base. Objects sharing a base never fill each other's paths: a
// subscription takes the push objects (the call without
// @subscription_type is push) or the pull ones by its type, and a
// distributor property comes from the procedure that sets it.
func (f frame) applies(o, rel string) bool {
	switch o {
	case "push_subscription":
		return f.sub != nil && deref(f.sub.Type) != "pull"
	case "pull_subscription", "subscriber_pull_subscription":
		return f.sub != nil && deref(f.sub.Type) == "pull"
	case "distributor", "distribution_db", "distpublisher":
		return distributorOwner(rel) == o
	}
	return true
}

// distributorOwners: the distributor properties that sp_adddistributiondb
// and sp_adddistpublisher set; every other one is sp_adddistributor's.
var distributorOwners = map[string]string{
	"min_retention_hours": "distribution_db", "max_retention_hours": "distribution_db",
	"history_retention_hours": "distribution_db", "delete_batch_size_xact": "distribution_db",
	"delete_batch_size_cmd": "distribution_db", "data_folder": "distribution_db", "data_file": "distribution_db",
	"log_folder": "distribution_db", "log_file": "distribution_db", "data_file_size_mb": "distribution_db",
	"log_file_size_mb": "distribution_db", "creation_connection": "distribution_db",
	"working_directory": "distpublisher", "publisher_connection": "distpublisher", "trusted": "distpublisher",
}

func distributorOwner(rel string) string {
	key, _, _ := strings.Cut(rel, ".")
	if o, ok := distributorOwners[key]; ok {
		return o
	}
	return "distributor"
}

func (f frame) context(object string) Context {
	ctx := Context{Object: object}
	if f.pub != nil {
		ctx.PubType, ctx.SyncMethod = deref(f.pub.Type), deref(f.pub.SyncMethod)
	}
	if f.art != nil {
		ctx.ArticleKind = articleKind(f.art.Type)
	}
	return ctx
}

// lookup finds the default of the property at the path pattern pattern.
func (n *normalizer) lookup(f frame, pattern string) (Default, bool) {
	for _, o := range objectOrder {
		base := objectBases[o]
		if rel, ok := strings.CutPrefix(pattern, base+"."); ok && f.applies(o, rel) {
			if d, ok := lookup(n.table, f.context(o), rel); ok {
				return d, true
			}
		}
	}
	return Default{}, false
}

// notMeasured is the refusal of a property with no default for its context.
func (f frame) notMeasured(pattern string) string {
	if f.pub != nil && deref(f.pub.Type) == "snapshot" && strings.HasPrefix(pattern, "publications[*].subscriptions[*].") {
		rel := strings.TrimPrefix(pattern, "publications[*].subscriptions[*].")
		return fmt.Sprintf("default of %s not measured on snapshot publications", rel)
	}
	for _, o := range objectOrder {
		if rel, ok := strings.CutPrefix(pattern, objectBases[o]+"."); ok && f.applies(o, rel) {
			ctx := f.context(o)
			var parts []string
			for _, s := range []string{ctx.PubType, ctx.SyncMethod, ctx.ArticleKind} {
				if s != "" {
					parts = append(parts, s)
				}
			}
			desc := o
			if len(parts) > 0 {
				desc += " (" + strings.Join(parts, ", ") + ")"
			}
			return fmt.Sprintf("default of %s for %s not measured", rel, desc)
		}
	}
	return fmt.Sprintf("default of %s for any object not measured", pattern)
}

// Rule 5: defaults by context, object by object from the outside in.
func (n *normalizer) defaults(c *model.Config) {
	v := reflect.ValueOf(c).Elem()
	n.fillStruct(v, "", nil, frame{})
}

// Properties rule 5 never fills: required ones (rule 2), those kept current
// on an existing object and not passed at creation (rule 6, R14, R41), the
// generated ones, and secret names, which name a value and have no default.
//
// The instance-dependent values (controller's ruling for Task 6): the
// distribution database folders and files and the distributor's
// working_directory (11-defaults rows rFolder and rFile: the instance's
// folders, measured on the lab container only), and a pull agent's
// distributor (rDistname: defaults to the publisher name). Omitted, they are
// neither filled nor refused: not passed at creation, so the server's own
// default applies, and kept current on an existing object (rule 6), so they
// are not compared.
var instanceDependent = map[reflect.Type]map[string]bool{
	reflect.TypeFor[model.Distributor](): {"data_folder": true, "data_file": true, "log_folder": true, "log_file": true, "working_directory": true},
	reflect.TypeFor[model.PullAgent]():   {"distributor": true},
}

var agentKept = map[string]bool{"job_name": true, "job_enabled": true, "run_as": true, "command": true, "profile": true, "schedules": true}

func notFilled(judge reflect.Value, key string) bool {
	if strings.HasSuffix(key, "_secret") {
		return true
	}
	t := judge.Type()
	if instanceDependent[t][key] {
		return true
	}
	if t == reflect.TypeFor[model.SharedPullAgent]() && instanceDependent[reflect.TypeFor[model.PullAgent]()][key] {
		return true
	}
	switch j := judge.Interface().(type) {
	case model.Config:
		return key == "distributor" // R4: an omitted distributor is the current one
	case model.Publisher:
		return key == "sync_with_backup" // R41
	case model.Publication:
		return key == "status"
	case model.Subscription:
		switch key {
		case "initialization":
			return true
		case "pull_agent": // none for a refused or omitted type
			return deref(j.Type) != "pull"
		case "distribution_agent":
			return deref(j.Type) != "push"
		}
	case model.Filter, model.Command:
		return key == "procedure" // required; generated, mode only
	case model.Article:
		return key == "identity_range_management" // R14
	case model.Agent, model.DistributionAgent, model.PullAgent, model.SharedPullAgent:
		return agentKept[key]
	}
	return false
}

var (
	commandType    = reflect.TypeFor[model.Command]()
	objectNameType = reflect.TypeFor[model.ObjectName]()
	scheduleType   = reflect.TypeFor[model.Schedule]()
	findingsType   = reflect.TypeFor[[]model.Finding]()
)

// fields calls fn for each YAML field of sv, inlined fields included.
func fields(sv reflect.Value, fn func(key string, fv reflect.Value)) {
	t := sv.Type()
	for i := range t.NumField() {
		f := t.Field(i)
		tag, ok := f.Tag.Lookup("yaml")
		if !f.IsExported() || !ok || f.Type == findingsType {
			continue
		}
		key, opts, _ := strings.Cut(tag, ",")
		if strings.Contains(","+opts+",", ",inline,") {
			fields(sv.Field(i), fn)
			continue
		}
		if key == "" {
			key = strings.ToLower(f.Name)
		}
		fn(key, sv.Field(i))
	}
}

type omissible interface {
	OmittedOK(key string, parents []model.Step) bool
}

func omittedOK(judge reflect.Value, key string, parents []model.Step) bool {
	o, ok := judge.Addr().Interface().(omissible)
	return ok && o.OmittedOK(key, parents)
}

// fillStruct fills the object sv at path: its own properties first, then
// each nested object, judged by OmittedOK on the filled object (the fold
// review's ruling: a publication without enabled_for_internet gets its
// default false, then no ftp defaults).
func (n *normalizer) fillStruct(sv reflect.Value, path string, parents []model.Step, f frame) {
	switch x := sv.Addr().Interface().(type) {
	case *model.Publication:
		f.pub = x
		n.publicationType(x, f)
	case *model.Article:
		f.art = x
		n.articleType(x, path, f)
	case *model.Subscription:
		f.sub = x
	}
	n.fillOwn(sv, path, parents, f)
	if d, ok := sv.Addr().Interface().(*model.Distributor); ok {
		n.fillProperties(d, path, f)
	}
	n.fillNested(sv, path, parents, f)
}

// fillOwn fills the nil scalar properties of sv, a command counting as one
// value (commands.insert).
func (n *normalizer) fillOwn(sv reflect.Value, path string, parents []model.Step, f frame) {
	fields(sv, func(key string, fv reflect.Value) {
		if fv.Kind() != reflect.Pointer || !fv.IsNil() {
			return
		}
		et := fv.Type().Elem()
		if et.Kind() == reflect.Struct && et != commandType {
			return
		}
		if notFilled(sv, key) || omittedOK(sv, key, parents) {
			return
		}
		p := model.Join(path, key)
		pattern := model.Pattern(p)
		if n.keepArticleValue(fv, f, pattern) {
			return
		}
		d, ok := n.lookup(f, pattern)
		if !ok {
			n.refuse(p, "%s", f.notMeasured(pattern))
			return
		}
		value := d.Value
		if et == commandType && strings.Contains(value, "{") {
			// A generated procedure stays nil, compared on its mode only
			// (rule 6): Fill's template is wrong for long names.
			value = decode.ParseCommand(value).Mode
		}
		if f.art != nil {
			value = Fill(value, f.art.Source.Schema, f.art.Source.Name)
		}
		if err := setDefault(fv, value); err != nil {
			n.refuse(p, "default %q (%s): %v", value, d.Row, err)
		}
	})
}

// articleBase is the pattern of an article; the article defaults' paths
// are relative to it.
const articleBase = "publications[*].articles[*]."

// syncDependent lists the article properties whose creation default
// depends on sync_method: those of the table whose values differ between
// two sync methods of the same publication type and article kind
// (destination.schema, under O16, and the commands among them).
func syncDependent(table []Default) map[string]bool {
	type group struct{ pubType, kind, path string }
	values := map[group]map[string]string{} // sync method -> value
	out := map[string]bool{}
	for _, d := range table {
		if d.Context.Object != "article" || d.Context.SyncMethod == "" {
			continue
		}
		g := group{d.Context.PubType, d.Context.ArticleKind, d.Path}
		if values[g] == nil {
			values[g] = map[string]string{}
		}
		for m, v := range values[g] {
			if m != d.Context.SyncMethod && v != d.Value {
				out[d.Path] = true
			}
		}
		values[g][d.Context.SyncMethod] = d.Value
	}
	return out
}

// keepArticleValue keeps, on an article that exists and is not replaced
// (R20), the current value of an omitted property whose creation default
// depends on sync_method (controller's ruling, Task 20 fix round 2), and
// tells whether it did. sp_changepublication sync_method rewrites neither
// dest_owner, schema_option nor the commands (measured by the Task 20
// review), so the default of either sync method would plan a change nobody
// asked for: the desired one rewrote the commands, the current one, once
// the change is applied, refused the next plan. A command keeps its mode
// only, its generated procedure not compared (rule 6). A current value
// that is nil leaves the property nil, not compared. A new or replaced
// article takes the desired context's defaults.
func (n *normalizer) keepArticleValue(fv reflect.Value, f frame, pattern string) bool {
	rel, ok := strings.CutPrefix(pattern, articleBase)
	if !ok || f.pub == nil || f.art == nil || !n.syncDep[rel] {
		return false
	}
	ca := n.currentArticle(f.pub.Name, f.art.Name)
	if ca == nil || ReplacedArticle(f.art, ca) {
		return false
	}
	cv := reflect.ValueOf(ca).Elem()
	for _, key := range strings.Split(rel, ".") {
		var next reflect.Value
		fields(cv, func(k string, v reflect.Value) {
			if k == key {
				next = v
			}
		})
		for next.IsValid() && next.Kind() == reflect.Pointer && next.Type().Elem().Kind() == reflect.Struct && next.Type() != reflect.PointerTo(commandType) {
			if next.IsNil() {
				return true
			}
			next = next.Elem()
		}
		if !next.IsValid() {
			return true
		}
		cv = next
	}
	if cv.Kind() != reflect.Pointer || cv.IsNil() {
		return true
	}
	if !n.someMethodDefault(rel, f, ca, cv) {
		return false
	}
	if c, ok := cv.Interface().(*model.Command); ok {
		fv.Set(reflect.ValueOf(&model.Command{Mode: c.Mode}))
		return true
	}
	nv := reflect.New(cv.Type().Elem())
	nv.Elem().Set(cv.Elem())
	fv.Set(nv)
	return true
}

// someMethodDefault tells whether the current value cv of the property rel
// of the existing article ca equals its creation default under some sync
// method of the article's group: the same publication type and article
// kind, the template filled with the article's source, a command compared
// by its mode only (controller's ruling, Task 20 fix round 3). Only such a
// value is kept: any other is drift, and takes the desired default, so that
// the plan changes it back (spec "Omitted properties"; measured by the
// round 2 re-review: destination_owner archive, ins_cmd SQL and an XCALL
// to a user procedure set by hand were no longer corrected). Known
// ambiguity, accepted by the controller: SQL stored on a native article is
// character's default, so it is kept and not corrected; a hand change to
// another sync method's default is never corrected.
func (n *normalizer) someMethodDefault(rel string, f frame, ca *model.Article, cv reflect.Value) bool {
	pubType, kind := deref(f.pub.Type), articleKind(ca.Type)
	if pubType == "" {
		pubType = "transactional"
	}
	for _, d := range n.table {
		if d.Context.Object != "article" || d.Path != rel || d.Context.SyncMethod == "" ||
			d.Context.PubType != "" && d.Context.PubType != pubType ||
			d.Context.ArticleKind != "" && d.Context.ArticleKind != kind {
			continue
		}
		v := Fill(d.Value, ca.Source.Schema, ca.Source.Name)
		switch c := cv.Interface().(type) {
		case *model.Command:
			if strings.EqualFold(decode.ParseCommand(v).Mode, c.Mode) {
				return true
			}
		case *string:
			if *c == v {
				return true
			}
		}
	}
	return false
}

// ReplacedArticle is R20's rule, which the planner applies too: the article
// is dropped and added back when its type family or its source changes, or
// the type of an article that is not a table. Only the logbased variants
// change their type in place (the cost table measures them alone, 02-matrix
// A21); two schema-only types are two kinds of objects. The source is
// compared without regard to case (a SQL identifier).
func ReplacedArticle(d, c *model.Article) bool {
	family := func(t *string) string {
		s := deref(t)
		if s == "" {
			s = "logbased"
		}
		switch {
		case strings.HasPrefix(s, "logbased"):
			return "table"
		case strings.HasSuffix(s, "proc_exec"):
			return "proc_exec"
		case strings.HasSuffix(s, "_schema_only"):
			return "schema_only"
		}
		return s
	}
	typ := func(t *string) string {
		if deref(t) == "" {
			return "logbased"
		}
		return deref(t)
	}
	if family(d.Type) != family(c.Type) || (family(d.Type) != "table" && typ(d.Type) != typ(c.Type)) {
		return true
	}
	return !strings.EqualFold(d.Source.Schema, c.Source.Schema) || !strings.EqualFold(d.Source.Name, c.Source.Name)
}

// fillNested allocates each omitted nested object that applies and fills
// every nested object.
func (n *normalizer) fillNested(sv reflect.Value, path string, parents []model.Step, f frame) {
	child := append(parents[:len(parents):len(parents)], model.Step{})
	fields(sv, func(key string, fv reflect.Value) {
		child[len(child)-1] = model.Step{Key: key, Value: sv.Addr().Interface()}
		if pub, ok := sv.Addr().Interface().(*model.Publication); ok && key == "articles" && concurrentOnSnapshot(pub) {
			return
		}
		p := model.Join(path, key)
		if fv.Kind() == reflect.Pointer {
			et := fv.Type().Elem()
			if et.Kind() != reflect.Struct || et == commandType || et == objectNameType {
				return
			}
			if fv.IsNil() {
				if notFilled(sv, key) || omittedOK(sv, key, parents) {
					return
				}
				fv.Set(reflect.New(et))
			}
			fv = fv.Elem()
		}
		switch fv.Kind() {
		case reflect.Struct:
			if fv.Type() == objectNameType {
				return
			}
			n.fillStruct(fv, p, child, f)
		case reflect.Slice:
			if et := fv.Type().Elem(); et.Kind() != reflect.Struct || et == scheduleType {
				return
			}
			for i := range fv.Len() {
				e := fv.Index(i)
				k := e.Addr().Interface().(interface{ Key() string }).Key()
				n.fillStruct(e, p+model.Element(k), child, f)
			}
		}
	})
}

// fillProperties fills the omitted keys of the MSdistributor properties.
func (n *normalizer) fillProperties(d *model.Distributor, path string, f frame) {
	for _, def := range n.table {
		key, ok := strings.CutPrefix(def.Path, "properties.")
		if !ok || objectBases[def.Context.Object] != "distributor" {
			continue
		}
		if _, ok := d.Properties[key]; ok {
			continue
		}
		if _, ok := n.lookup(f, "distributor."+def.Path); !ok {
			continue
		}
		if d.Properties == nil {
			d.Properties = map[string]string{}
		}
		d.Properties[key] = def.Value
	}
}

// setDefault stores a defaults table value into the nil pointer fv.
func setDefault(fv reflect.Value, v string) error {
	et := fv.Type().Elem()
	var x reflect.Value
	switch {
	case et == commandType:
		c := decode.ParseCommand(v)
		mc := model.Command{Mode: c.Mode}
		if c.Procedure != "" {
			mc.Procedure = &model.ObjectName{Schema: c.Schema, Name: c.Procedure}
		}
		x = reflect.ValueOf(mc)
	case et.Kind() == reflect.String:
		x = reflect.ValueOf(v).Convert(et)
	case et.Kind() == reflect.Bool:
		b, err := strconv.ParseBool(v)
		if err != nil {
			return err
		}
		x = reflect.ValueOf(b)
	case et.Kind() == reflect.Int:
		i, err := strconv.Atoi(v)
		if err != nil {
			return err
		}
		x = reflect.ValueOf(i)
	case et.Kind() == reflect.Slice && et.Elem().Kind() == reflect.String:
		xs, ok := ParseList(v)
		if !ok {
			return fmt.Errorf("not a list")
		}
		x = reflect.ValueOf(xs)
	default:
		return fmt.Errorf("no setter for %s", et)
	}
	p := reflect.New(et)
	p.Elem().Set(x)
	fv.Set(p)
	return nil
}

// publicationType fills an omitted type first, since every other default
// depends on it: the call without @repl_freq is the transactional context
// (11-defaults D.sp_addpublication.transactional.@repl_freq).
func (n *normalizer) publicationType(p *model.Publication, f frame) {
	if p.Type != nil {
		return
	}
	if d, ok := lookup(n.table, Context{Object: "publication", PubType: "transactional"}, "type"); ok {
		p.Type = model.Ptr(d.Value)
	}
}

// articleType fills an omitted type first, since the article's defaults
// depend on its kind: logbased for a table source. The source kind of an
// existing article comes from current; a new one is taken as a table, so a
// non-table source must write its type.
func (n *normalizer) articleType(a *model.Article, path string, f frame) {
	if a.Type != nil {
		return
	}
	if cur := n.currentArticle(f.pub.Name, a.Name); cur != nil && articleKind(cur.Type) != "table" {
		n.refuse(path+".type", "type of an article whose source is not a table (current type %s) must be written", deref(cur.Type))
		return
	}
	ctx := f.context("article")
	ctx.ArticleKind = "table"
	d, ok := lookup(n.table, ctx, "type")
	if !ok {
		n.refuse(path+".type", "%s", f.notMeasured("publications[*].articles[*].type"))
		return
	}
	a.Type = model.Ptr(d.Value)
}

// subdayRequired are the frequencies whose schedule SQL Server Agent stores
// with a nonzero subday type.
var subdayRequired = map[string]bool{"daily": true, "weekly": true, "monthly": true, "monthly_relative": true}

// ObjectBase returns the model path pattern the entries of object are
// relative to (objectBases).
func ObjectBase(object string) (string, bool) {
	b, ok := objectBases[object]
	return b, ok
}

// Rule 6: omitted means current (R4, R14, R22, R23, R37, R38, R41).
func (n *normalizer) keepCurrent(c *model.Config) {
	cur := n.current
	keep := func(dst **string, src *string) {
		if *dst == nil && src != nil {
			*dst = model.Ptr(*src)
		}
	}
	if cur != nil && cur.Distributor != nil {
		if c.Distributor == nil {
			c.Distributor = clone(&model.Config{Distributor: cur.Distributor}).Distributor
		} else {
			d, cd := c.Distributor, cur.Distributor
			keep(&d.DataFolder, cd.DataFolder)
			keep(&d.DataFile, cd.DataFile)
			keep(&d.LogFolder, cd.LogFolder)
			keep(&d.LogFile, cd.LogFile)
			keep(&d.WorkingDirectory, cd.WorkingDirectory)
		}
	}
	var curSync *bool
	if cur != nil {
		curSync = cur.Publisher.SyncWithBackup
	}
	switch sw := c.Publisher.SyncWithBackup; {
	case sw == nil && curSync != nil:
		c.Publisher.SyncWithBackup = model.Ptr(*curSync)
	case sw != nil && curSync != nil && *curSync != *sw:
		// A declared value on a database with no current one (a fresh
		// database) is set at creation (controller's ruling).
		n.refuse("publisher.sync_with_backup", "a sync_with_backup other than the current value is not measured (11-defaults holds no sync with backup row); omit it")
	}
	for i := range c.Publications {
		p := &c.Publications[i]
		for j := range p.Articles {
			a := &p.Articles[j]
			if ca := n.currentArticle(p.Name, a.Name); ca != nil {
				keep(&a.IdentityRangeManagement, ca.IdentityRangeManagement)
			}
		}
	}
	for _, r := range agents(c) {
		if r.snapshot && r.agent.JobEnabled == nil {
			r.agent.JobEnabled = model.Ptr(true) // R23
		}
		if r.agent.Schedules != nil {
			for k := range *r.agent.Schedules {
				s := &(*r.agent.Schedules)[k]
				if s.EndDate == 0 {
					s.EndDate = 99991231 // R38
				}
				if s.EndTime == 0 {
					s.EndTime = 235959
				}
				if s.Subday == "" && subdayRequired[s.Frequency] {
					// Measured by the Task 8 review: @frequency_subday = NULL
					// with a daily schedule stores freq_subday_type 1, read
					// back as at_time, so "" would never converge.
					s.Subday = "at_time"
				}
			}
		}
		cr := n.currentAgent(r.key)
		if cr == nil {
			continue
		}
		keep(&r.agent.JobName, cr.agent.JobName)
		keep(&r.agent.RunAs, cr.agent.RunAs)
		keep(&r.agent.Command, cr.agent.Command)
		if r.agent.JobEnabled == nil && cr.agent.JobEnabled != nil {
			r.agent.JobEnabled = model.Ptr(*cr.agent.JobEnabled)
		}
		if r.pull != nil && cr.pull != nil {
			keep(&r.pull.Distributor, cr.pull.Distributor)
		}
	}
}

// passwords: a connection the plan creates with SQL Server authentication
// needs the name of its password secret (controller's ruling); on an
// existing object a nil one stays nil and is not compared.
func (n *normalizer) passwords(c *model.Config) {
	const reason = "a SQL login needs its password_secret"
	need := func(path string, cn *model.Connection) {
		if cn != nil && deref(cn.Security) == "sql" && cn.PasswordSecret == nil {
			n.refuse(path+".password_secret", reason)
		}
	}
	for _, r := range agents(c) {
		if n.currentAgent(r.key) == nil {
			need(r.path+".connection", r.agent.Connection)
			need(r.path+".distributor_connection", r.agent.DistributorConnection)
		}
	}
	if d := c.Distributor; d != nil && (n.current == nil || n.current.Distributor == nil) {
		need("distributor.publisher_connection", d.PublisherConnection)
		if deref(d.AdminLinkSecurity) == "sql" && d.AdminPasswordSecret == nil {
			n.refuse("distributor.admin_password_secret", reason)
		}
	}
}

// Rule 7: combinations the server refuses, after defaults.
func (n *normalizer) conflicts(c *model.Config) {
	// One default profile per agent type: sp_add_agent_profile @default = 1
	// takes the flag from the previous one (19-profiles PF.create_default).
	defaults := map[string]string{}
	for _, pr := range c.AgentProfiles {
		if pr.Default == nil || !*pr.Default {
			continue
		}
		if other, ok := defaults[pr.AgentType]; ok {
			n.refuse("agent_profiles"+model.Element(pr.Key())+".default", "profiles %s and %s are both the default of %s", other, pr.Name, pr.AgentType)
			continue
		}
		defaults[pr.AgentType] = pr.Name
	}
	if d := c.Distributor; d != nil && d.MinRetentionHours != nil && d.MaxRetentionHours != nil && *d.MinRetentionHours > *d.MaxRetentionHours {
		// Measured by the Task 14 review: sp_changedistributiondb refuses a
		// min above the max, and a max below the min, with 14107.
		n.refuse("distributor.min_retention_hours", "min_distretention %d is above max_distretention %d (14107, measured)",
			*d.MinRetentionHours, *d.MaxRetentionHours)
	}
	for i := range c.Publications {
		p := &c.Publications[i]
		pp := pubPath(p)
		imm := isTrue(p.ImmediateSync)
		if imm && isFalse(p.IndependentAgent) {
			n.refuse(pp+".immediate_sync", "immediate_sync requires independent_agent (21022)")
		}
		if isTrue(p.AllowAnonymous) && !imm {
			n.refuse(pp+".allow_anonymous", "allow_anonymous requires immediate_sync (20011)")
		}
		if isTrue(p.AllowSubscriptionCopy) && !imm {
			n.refuse(pp+".allow_subscription_copy", "allow_subscription_copy requires immediate_sync (21210)")
		}
		if isTrue(p.ReplicatePartitionSwitch) && isFalse(p.AllowPartitionSwitch) {
			n.refuse(pp+".replicate_partition_switch", "replicate_partition_switch requires allow_partition_switch (21866)")
		}
		if s := p.Snapshot; s != nil {
			if isTrue(s.Compress) && deref(s.AltFolder) == "" {
				n.refuse(pp+".snapshot.compress", "a compressed snapshot requires alt_folder (21157)")
			}
			if isTrue(s.EnabledForInternet) && (s.FTP == nil || deref(s.FTP.Address) == "") {
				n.refuse(pp+".snapshot.enabled_for_internet", "enabled_for_internet requires ftp.address (21158)")
			}
		}
		if concurrentOnSnapshot(p) {
			n.refuse(pp+".sync_method", "a snapshot publication cannot use sync_method %s (22547)", deref(p.SyncMethod))
		}
		if isTrue(p.EnabledForHetSub) {
			n.refuse(pp+".enabled_for_het_sub", "non-SQL Server subscribers are out of scope (spec \"Scope\")")
		}
		for j := range p.Articles {
			a := &p.Articles[j]
			if deref(a.IdentityRangeManagement) == "auto" {
				n.refuse(artPath(p, a)+".identity_range_management", "automatic identity range management is out of scope (spec \"Scope\")")
			}
		}
		for j := range p.Subscriptions {
			s := &p.Subscriptions[j]
			sp := subPath(p, s)
			if deref(p.Status) == "inactive" {
				n.refuse(sp, "a subscription to an inactive publication is refused (21000)")
			}
			switch deref(s.Type) {
			case "pull":
				if isFalse(p.AllowPull) {
					n.refuse(sp+".type", "a pull subscription requires allow_pull (20012)")
				}
			case "push":
				if isFalse(p.AllowPush) {
					n.refuse(sp+".type", "a push subscription requires allow_push (20012)")
				}
			case "anonymous":
				n.refuse(sp+".type", "anonymous subscriptions are out of scope (spec \"Scope\")")
			}
			if t := deref(s.SubscriberType); t != "" && t != "sql_server" {
				n.refuse(sp+".subscriber_type", "non-SQL Server subscribers are out of scope (spec \"Scope\")")
			}
			if len(s.Articles) > 0 && !p.SubsetAllowed() {
				if m := deref(p.SyncMethod); m == "concurrent" || m == "concurrent_c" {
					n.refuse(sp+".articles", "a subscription to a subset of the articles of a %s publication is refused (14100)", m)
				} else {
					n.refuse(sp+".articles", "a subscription to a subset of the articles of an immediate_sync publication is refused (14122)")
				}
			}
		}
	}
	for _, r := range agents(c) {
		if r.agent.Schedules == nil {
			continue
		}
		cr := n.currentAgent(r.key)
		for _, s := range *r.agent.Schedules {
			sp := r.path + ".schedules" + model.Element(s.Key())
			if isFalse(s.Enabled) && !currentlyDisabled(cr) {
				n.refuse(sp+".enabled", "a schedule's enabled cannot be set by a replication procedure (R38)")
			}
			switch s.Frequency {
			case "daily", "weekly", "monthly", "monthly_relative":
				if s.Interval == 0 {
					n.refuse(sp+".interval", "interval of a %s schedule must be written (R38)", s.Frequency)
				}
			}
		}
	}
}

// currentlyDisabled: the current agent exists and its schedule is disabled.
// Schedules are matched without their name (R22), and an agent has one.
func currentlyDisabled(cr *agentRef) bool {
	if cr == nil || cr.agent.Schedules == nil || len(*cr.agent.Schedules) == 0 {
		return false
	}
	return isFalse((*cr.agent.Schedules)[0].Enabled)
}

// Rule 8 (R14): identity_property is not compared on an article whose
// normalized or current identity_range_management is manual.
func (n *normalizer) identityOption(c *model.Config) {
	for i := range c.Publications {
		p := &c.Publications[i]
		for j := range p.Articles {
			a := &p.Articles[j]
			manual := deref(a.IdentityRangeManagement) == "manual"
			if ca := n.currentArticle(p.Name, a.Name); ca != nil && deref(ca.IdentityRangeManagement) == "manual" {
				manual = true
			}
			if !manual || a.SchemaOptions == nil {
				continue
			}
			opts := []string{}
			for _, o := range *a.SchemaOptions {
				if o != "identity_property" {
					opts = append(opts, o)
				}
			}
			a.SchemaOptions = &opts
		}
	}
}

// Rule 9: with timestamp_as_timestamp, insert_column_names derives from the
// schema option (spec "What is not compared", lab row 3: sp_addarticle sets
// the status bit 0x8 with schema option 0x8). It takes the current value of
// an existing article, and true for a new one.
func (n *normalizer) timestampColumns(c *model.Config) {
	for i := range c.Publications {
		p := &c.Publications[i]
		for j := range p.Articles {
			a := &p.Articles[j]
			if a.SchemaOptions == nil || !contains(*a.SchemaOptions, "timestamp_as_timestamp") {
				continue
			}
			v := true
			if ca := n.currentArticle(p.Name, a.Name); ca != nil && ca.InsertColumnNames != nil {
				v = *ca.InsertColumnNames
			}
			a.InsertColumnNames = model.Ptr(v)
		}
	}
}

func contains(xs []string, s string) bool {
	for _, x := range xs {
		if x == s {
			return true
		}
	}
	return false
}
