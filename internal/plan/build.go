package plan

import (
	"fmt"
	"reflect"
	"strings"

	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/normalize"
)

// strategy adds a part of the plan's operations and refusals (spec
// "Strategies"). Tasks 11 to 14 append theirs; the order of operations is
// finish's sort by (Step, Order), never the order of registration.
//
// The contracts finish reads (Task 9): every operation with a cost entry
// names its publication in Affects.Publications[0], an article-scoped one
// its article in Affects.Articles[0], a subscription operation its
// subscription in Affects.Subscriptions; finish panics otherwise. finish
// overwrites Affects.Subscriptions on a reinit-flagged change, and the
// SubState.StartAgent of the predicted state is read after finish.
type strategy func(b *builder)

var strategies []strategy

// lateStrategies run after every strategy of strategies, in this order:
// they read what the others planned (b.ops, b.dropped, b.readd,
// b.sharedPush). agentsStrategy comes before distributorStrategy, whose
// profile drop of step 11 reads the bindings agentsStrategy plans
// (b.rebound): an agent bound away from a profile frees it in the same plan
// (TestProfileDropAfterRebinding). redeliveriesStrategy comes last: it reads
// every drop and every addition of the plan.
var lateStrategies = []strategy{agentsStrategy, distributorStrategy, redeliveriesStrategy}

// builder is the state Build hands the strategies.
type builder struct {
	in              Inputs
	opt             Options
	des, cur        *model.Config // normalized desired, current
	st              *State
	ops             []Operation
	refusals        []Refusal
	warnings, notes []string
	skip            func(path string) bool // the unreadable paths
	// sharedPush is the shared distribution agents, by lower-cased
	// subscriber/database, that an sp_addpushsubscription_agent of this plan
	// creates (subscriptions.go): a later subscription to the same subscriber
	// database emits none.
	sharedPush map[string]bool
	// dropped is the current subscriptions this plan drops whole, by
	// "<pub>\x00<lower-cased key>" (dropSubscription): sharedPushExists
	// reads it.
	dropped map[string]bool
	// readd is the kept subscriptions this plan drops in step 4 and adds
	// back in step 9 for a change of independent_agent, by
	// "<pub>\x00<lower-cased key>" (readdSubscription): addSubscription
	// costs their re-add.
	readd map[string]bool
	// deferrals memoizes deferred (defer.go), by publication name.
	deferrals map[string]bool
	// rebound is the profile each agent this plan binds is bound to, by
	// agentKey (agents.go): the profile drop of step 11 reads it.
	rebound map[string]string
	// deferStarts is the agents to start of a deferred publication, by ref,
	// to the publication (agentsToStart): their job_start goes after its
	// generate_and_wait (addJobOps).
	deferStarts map[AgentRef]string
}

func (b *builder) refuse(path, format string, args ...any) {
	b.refusals = append(b.refusals, Refusal{Path: path, Reason: fmt.Sprintf(format, args...)})
}

// unmeasured refuses a change no cost entry covers: "cost of <pattern>
// change not measured" (spec "Costs and unmeasured changes"), or the reason
// of its own a refused pattern has (refusedChanges).
func (b *builder) unmeasured(c Change) {
	if reason, ok := refusedChange(c.Pattern); ok {
		b.refuse(c.Path, "%s", reason)
		return
	}
	b.refuse(c.Path, "cost of %s change not measured", c.Pattern)
}

// diff is diffObject with the type of the publication the path is under,
// which an omitted schedule's default depends on, and the builder's skip.
func (b *builder) diff(path string, desired, current any) []Change {
	pubType := ""
	for i := range b.des.Publications {
		p := &b.des.Publications[i]
		pp := "publications" + model.Element(p.Name)
		if (path == pp || strings.HasPrefix(path, pp+".")) && p.Type != nil {
			pubType = *p.Type
		}
	}
	return diffIn(pubType, path, desired, current, b.skip)
}

// Build: Normalize, refuse on out_of_scope and on the incomplete findings no
// rule repairs (R26), normalize the current side's R14 bit, match objects
// (R7), call the strategies, finish, then the plan-level lists (lists.go):
// the job operations, the preconditions, the agents to start, the secrets,
// the warnings and the notes.
//
// Matching is the strategies' (matchPublications and its siblings), each
// on the lists it plans, and a matched pair is diffed at pair.path, built
// from the current key. A refused plan has no operation (R3): when the
// normalization, the schedules (scheduleRefusals, R22) or the findings
// refuse, the strategies do not run, since their input is not the
// configuration the file means; when a strategy refuses, the operations
// are dropped.
func Build(in Inputs, opt Options) *Plan {
	b := &builder{in: in, opt: opt}
	des, refusals := normalize.Normalize(in.Desired, in.Current)
	b.des, b.refusals = des, append(refusals, scheduleRefusals(des)...)

	b.cur = &model.Config{Version: model.FormatVersion}
	if in.Current != nil {
		b.cur = cloneConfig(in.Current)
	}
	for _, f := range b.cur.Findings {
		switch f.Kind {
		case model.FindingOutOfScope:
			// R26: the database is refused, one refusal per finding.
			b.refuse(f.Path, "%s", f.Message)
		case model.FindingUnreadable:
			b.notes = append(b.notes, fmt.Sprintf("%s could not be read and is not compared: %s", f.Path, f.Message))
		case model.FindingIncomplete:
			b.incomplete(f) // R26
		}
	}
	b.skip = unreadable(b.cur)
	before := NewState(b.cur, in.Facts) // the state observed before the plan

	p := &Plan{Publisher: des.Publisher.Server, Database: des.Publisher.Database, Options: opt}
	if len(b.refusals) == 0 {
		identityBit(b.des, b.cur)
		foldColumns(b.des, in.Checks)
		foldColumns(b.cur, in.Checks)
		b.st = NewState(b.cur, in.Facts)
		for _, s := range strategies {
			s(b)
		}
		for _, s := range lateStrategies {
			s(b)
		}
	}
	if len(b.refusals) == 0 {
		ops, rs := finish(b.ops, b.st)
		b.refusals = append(b.refusals, rs...)
		if len(b.refusals) == 0 {
			p.Operations = ops
		}
	}
	b.lists(p, before)
	p.Refusals = b.refusals
	p.Warnings = b.warnings
	p.Notes = b.notes
	p.Totals = totals(p.Operations)
	return p
}

// identityBit removes identity_property from the schema options of a
// current article whose current or desired identity_range_management is
// manual (R14): sp_addarticle with manual adds it, so it is not compared.
// Normalization does the same on the desired side (rule 8).
func identityBit(des, cur *model.Config) {
	manual := map[string]bool{}
	for _, p := range des.Publications {
		for _, a := range p.Articles {
			if a.IdentityRangeManagement != nil && *a.IdentityRangeManagement == "manual" {
				manual[p.Name+"\x00"+a.Name] = true
			}
		}
	}
	for i := range cur.Publications {
		p := &cur.Publications[i]
		for j := range p.Articles {
			a := &p.Articles[j]
			isManual := a.IdentityRangeManagement != nil && *a.IdentityRangeManagement == "manual"
			if a.SchemaOptions == nil || !(isManual || manual[p.Name+"\x00"+a.Name]) {
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

// cloneConfig deep-copies a configuration, so that Build never changes its
// inputs.
func cloneConfig(c *model.Config) *model.Config {
	out := new(model.Config)
	deepCopy(reflect.ValueOf(out).Elem(), reflect.ValueOf(c).Elem())
	return out
}

func deepCopy(dst, src reflect.Value) {
	switch src.Kind() {
	case reflect.Pointer:
		if src.IsNil() {
			return
		}
		v := reflect.New(src.Type().Elem())
		deepCopy(v.Elem(), src.Elem())
		dst.Set(v)
	case reflect.Struct:
		for i := range src.NumField() {
			deepCopy(dst.Field(i), src.Field(i))
		}
	case reflect.Slice:
		if src.IsNil() {
			return
		}
		s := reflect.MakeSlice(src.Type(), src.Len(), src.Len())
		for i := range src.Len() {
			deepCopy(s.Index(i), src.Index(i))
		}
		dst.Set(s)
	case reflect.Map:
		if src.IsNil() {
			return
		}
		m := reflect.MakeMapWithSize(src.Type(), src.Len())
		for it := src.MapRange(); it.Next(); {
			v := reflect.New(src.Type().Elem()).Elem()
			deepCopy(v, it.Value())
			m.SetMapIndex(it.Key(), v)
		}
		dst.Set(m)
	default:
		dst.Set(src)
	}
}
