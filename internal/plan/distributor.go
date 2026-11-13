package plan

import (
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/rudi-bruchez/sqlserver-replication/internal/cost"
	"github.com/rudi-bruchez/sqlserver-replication/internal/decode"
	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/normalize"
)

// distributorStrategy is listed in lateStrategies (build.go), after
// agentsStrategy.

// The refusals of the distributor and the profiles (R6, R17, spec
// "Non-goals").
const (
	r17Remote       = "remote distributor setup not measured (distributor-defaults ran on a local distributor only)"
	distributorMove = "moving a publication database to another distributor drops every publication (spec Non-goals)"
	noDistChange    = "no procedure changes %s of an existing distribution database"
	r4Declare       = "the file must declare the distributor to create"
	r6Default       = "changing the default profile is not measured; only sp_add_agent_profile @default sets it"
	r6NoTemplate    = "the parameters sp_add_agent_profile copies into a new %s profile are not known: plan needs the facts (template_profile_parameters, R6)"
	r6NotDropped    = "profile %s (%s) is at the distributor and not in the file: not dropped; drop it by hand if it is unused"
)

// The Order keys of steps 1 and 2 (finish sorts by (Step, Order)):
//
//   - step 1: 1 sp_adddistributor, 2 sp_adddistributiondb, 3
//     sp_adddistpublisher, then "4\x00<rank>\x00<path>" for a change, the
//     rank ordering the two retention calls (retentionOrder);
//   - step 2: "<agent type>\x00<lower-cased name>\x00" then 1 for
//     sp_add_agent_profile, 2 for sp_change_agent_profile, and
//     "3\x00<lower-cased parameter>" for a parameter call.

// distFixed are the distributor properties no procedure changes once the
// distribution database exists: its folders and files.
var distFixed = map[string]bool{"data_folder": true, "data_file": true, "log_folder": true, "log_file": true}

// distributorStrategy plans the distributor (step 1, R17, spec "Shared
// distributor objects") and the user profiles (step 2, R6).
// An omitted agent_profiles key (nil after model.Load) means the file does
// not manage the profiles: no profile operation and no note. An explicit
// empty list notes every user profile at the distributor (R6 as amended on
// 2026-11-13: a profile is never dropped).
func distributorStrategy(b *builder) {
	b.planDistributor()
	if b.in.Desired != nil && b.in.Desired.AgentProfiles != nil {
		b.planProfiles()
	}
}

// shared is the other publication databases the distributor serves,
// "<publisher>.<database>", sorted (spec "Shared distributor objects").
func (b *builder) shared() []string {
	if b.in.Facts == nil {
		return nil
	}
	seen := map[string]bool{}
	var out []string
	for _, d := range b.in.Facts.PublisherDatabases {
		if strings.EqualFold(d.Publisher, b.des.Publisher.Server) && strings.EqualFold(d.Database, b.des.Publisher.Database) {
			continue
		}
		k := d.Publisher + "." + d.Database
		if !seen[strings.ToLower(k)] {
			seen[strings.ToLower(k)] = true
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out
}

// markShared gives a change to a shared object its cost and its list.
func (b *builder) markShared(op *Operation) {
	if s := b.shared(); len(s) > 0 {
		op.Shared = s
		op.Costs = append(op.Costs, CostSharedObjectChanged)
	}
}

// distributorServer is the distributor's name as the file writes it.
func (b *builder) distributorServer() string {
	if d := b.des.Distributor; d != nil && d.Server != "" {
		return d.Server
	}
	if d := b.cur.Distributor; d != nil {
		return d.Server
	}
	return b.des.Publisher.Server
}

// distributionDB is the distribution database's name.
func (b *builder) distributionDB() string {
	if d := b.des.Distributor; d != nil && d.Database != "" {
		return d.Database
	}
	if d := b.cur.Distributor; d != nil && d.Database != "" {
		return d.Database
	}
	return "distribution"
}

// distOp is an operation at the distributor, in the database its
// procedure's context names (procContexts).
func (b *builder) distOp(step int, order, kind, action, path string, call Call) Operation {
	op := b.newOp(step, order, kind, action, path, call)
	op.Server = b.distributorServer()
	op.Database = "master"
	if ctx, ok := procContexts[call.Procedure]; ok {
		switch ctx.Database {
		case "distribution":
			op.Database = b.distributionDB()
		case "msdb":
			op.Database = "msdb"
		}
	}
	return op
}

// withCites sets an operation's entry and adds its cites to Sources.
func withCites(op *Operation, e cost.Entry) {
	op.entry = &e
	for _, c := range e.Cites {
		op.Sources = append(op.Sources, c.Row)
	}
}

// planDistributor: create the distributor locally when there is none, or
// register the publisher at a local distributor that does not know it (R17);
// refuse a remote setup and a move; otherwise change what the cost table
// covers.
func (b *builder) planDistributor() {
	des, cur := b.des.Distributor, b.cur.Distributor
	pub := b.des.Publisher.Server
	if des == nil {
		// Neither side has one (normalization copies the current
		// distributor into a file that omits it): R4.
		b.refuse("distributor", "%s", r4Declare)
		return
	}
	local := strings.EqualFold(des.Server, pub)
	switch {
	case cur == nil:
		if !local {
			b.refuse("distributor.server", "%s", r17Remote)
			return
		}
		b.createDistributor(des)
		return
	case !strings.EqualFold(des.Server, cur.Server):
		b.refuse("distributor.server", "%s", distributorMove)
		return
	case cur.Database == "":
		// The distributor exists and does not know this publisher (the
		// reader's lenient read).
		if des.Database == "" {
			b.refuse("distributor.database", "%s", r4Declare)
			return
		}
		if !strings.EqualFold(cur.Server, pub) {
			b.refuse("distributor.server", "%s", r17Remote)
			return
		}
		b.addDistPublisher(des, "the distributor exists and this publisher is not registered at it")
		return
	}
	if b.skip("distributor") {
		return
	}
	retention := retentionOrder(des, cur)
	for _, ch := range b.diff("distributor", des, cur) {
		rel := strings.TrimPrefix(ch.Pattern, "distributor.")
		switch {
		case rel == "server" || rel == "database":
			b.refuse(ch.Path, "%s", distributorMove)
			continue
		case distFixed[rel]:
			b.refuse(ch.Path, noDistChange, rel)
			continue
		}
		b.distributorChange(ch, retention[rel])
	}
}

// retentionOrder is the Order keys of the min and max retention changes.
// Measured by the Task 14 review: sp_changedistributiondb refuses with
// 14107 a state where max_distretention is below min_distretention (equal
// is accepted), so the two calls run in the order that keeps min <= max at
// each step: max first when it goes up, min first otherwise (both down, or
// max down and min up). Normalization refuses a desired min above max.
func retentionOrder(des, cur *model.Distributor) map[string]string {
	up := des.MaxRetentionHours != nil && cur.MaxRetentionHours != nil && *des.MaxRetentionHours > *cur.MaxRetentionHours
	if up {
		return map[string]string{"max_retention_hours": "1", "min_retention_hours": "2"}
	}
	return map[string]string{"min_retention_hours": "1", "max_retention_hours": "2"}
}

// createDistributor is step 1 on a server without a distributor:
// sp_adddistributor in master, sp_adddistributiondb, sp_adddistpublisher
// (distributor-defaults, the only measured setup, R17).
func (b *builder) createDistributor(d *model.Distributor) {
	call, err := creationCall("sp_adddistributor", d, normalize.Context{Object: "distributor"},
		[]Param{{Name: "@distributor", Value: literal(d.Server)}})
	if err != nil {
		b.refuse("distributor", "%v", err)
		return
	}
	op := b.distOp(1, "1", "distributor", "add", "distributor", call)
	op.Reason = "the publisher has no distributor: it is created locally (R17)"
	op.Sources = append(op.Sources, "spec Order step 1", "R17")
	b.add(op)

	call, err = creationCall("sp_adddistributiondb", d, normalize.Context{Object: "distribution_db"},
		[]Param{{Name: "@database", Value: literal(d.Database)}})
	if err != nil {
		b.refuse("distributor", "%v", err)
		return
	}
	op = b.distOp(1, "2", "distribution_db", "add", "distributor", call)
	op.Reason = "the distribution database of the distributor the plan creates"
	op.Sources = append(op.Sources, "spec Order step 1", "R17")
	b.add(op)

	b.addDistPublisher(d, "the publisher is registered at the distributor the plan creates")
}

// addDistPublisher registers the publisher at a local distributor.
func (b *builder) addDistPublisher(d *model.Distributor, reason string) {
	call, err := creationCall("sp_adddistpublisher", d, normalize.Context{Object: "distpublisher"}, []Param{
		{Name: "@publisher", Value: literal(b.des.Publisher.Server)},
		{Name: "@distribution_db", Value: literal(d.Database)},
	})
	if err != nil {
		b.refuse("distributor", "%v", err)
		return
	}
	op := b.distOp(1, "3", "distpublisher", "add", "distributor", call)
	op.Reason = reason
	op.Sources = append(op.Sources, "spec Order step 1", "R17")
	b.add(op)
}

// distributorChange is one sp_changedistributiondb or sp_changedistpublisher
// for a changed property of the distributor, its entry from cost.Lookup; a
// change of a shared object (spec "Shared distributor objects").
func (b *builder) distributorChange(ch Change, rank string) {
	e, ok := lookupChange(ch)
	if !ok {
		b.unmeasured(ch)
		return
	}
	if e.Class == cost.Refused {
		b.refuse(ch.Path, "%s change refused by the server (%d)", ch.Pattern, e.Error)
		return
	}
	rel := strings.TrimPrefix(ch.Pattern, "distributor.")
	v, ok := resolve(b.des.Distributor, rel)
	if !ok {
		b.refuse(ch.Path, "%s has no value to set", ch.Pattern)
		return
	}
	enc, ok := valueEncoders[[2]string{e.Procedure, e.Property}]
	if !ok {
		b.refuse(ch.Path, "no measured @value form for %s %s", e.Procedure, e.Property)
		return
	}
	lit, err := enc(v)
	if err != nil {
		b.refuse(ch.Path, "%v", err)
		return
	}
	var first Param
	switch e.Procedure {
	case "sp_changedistributiondb":
		first = Param{Name: "@database", Value: literal(b.distributionDB())}
	case "sp_changedistpublisher":
		first = Param{Name: "@publisher", Value: literal(b.des.Publisher.Server)}
	default:
		b.refuse(ch.Path, "no measured call for %s", ch.Pattern)
		return
	}
	op := b.distOp(1, "4"+sep+rank+sep+ch.Path, "distributor_property", "change", "distributor", Call{Procedure: e.Procedure, Params: []Param{
		first, {Name: "@property", Value: literal(e.Property)}, {Name: "@value", Value: lit},
	}})
	withCites(&op, e)
	op.Changes = []PropertyChange{{Path: ch.Path, Before: orEmpty(ch.Before), After: orEmpty(ch.After)}}
	op.Reason = "the distributor's " + rel + " changes"
	op.Sources = append(op.Sources, "spec Shared distributor objects")
	b.markShared(&op)
	b.add(op)
}

// lookupChange is the cost entry of a change outside a publication, by its
// directions (stored under transactional, cost.Lookup).
func lookupChange(ch Change) (cost.Entry, bool) {
	for _, dir := range directions(ch) {
		if e, ok := cost.Lookup(ch.Path, dir, "transactional"); ok {
			return e, true
		}
	}
	return cost.Entry{}, false
}

// dropParameterMeasured tells whether 19-profiles PF.drop_parameter is ok,
// read through the profile parameters' cost entry (R6): otherwise a copied
// parameter the file omits is kept and not compared.
func dropParameterMeasured() bool {
	e, ok := cost.Lookup("agent_profiles[*].parameters", "", "transactional")
	if !ok {
		return false
	}
	for _, c := range e.Cites {
		if strings.HasSuffix(c.Row, "PF.drop_parameter") && c.Expect == "ok" {
			return true
		}
	}
	return false
}

func profilePath(p *model.AgentProfile) string { return "agent_profiles" + model.Element(p.Key()) }

func profileOrder(p *model.AgentProfile) string {
	return p.AgentType + sep + strings.ToLower(p.Name) + sep
}

// profilePrologue finds the profile's id in the batch: the profile may not
// exist when plan runs (Task 14).
func profilePrologue(p *model.AgentProfile) (string, error) {
	code, err := decode.AgentTypeCode(p.AgentType)
	if err != nil {
		return "", err
	}
	return "DECLARE @profile_id int;\n" +
		"SELECT @profile_id = profile_id FROM msdb.dbo.MSagent_profiles WHERE profile_name = " + literal(p.Name) +
		" AND agent_type = " + strconv.Itoa(code) + ";\n" +
		"IF @profile_id IS NULL THROW 50000, " + literal("profile "+p.Name+" ("+p.AgentType+") not found") + ", 1;", nil
}

// planProfiles creates and changes the user profiles of the file (step 2),
// R6; profiles are matched by agent type and by name without regard to case
// (R7). Every one is a change of a shared object. A profile at the
// distributor that the file omits is never dropped (R6 as amended on
// 2026-11-13, decided by Rudi): the export lists every profile of the
// distributor, so a stale file would drop another team's unused profile.
// The plan notes it instead.
func (b *builder) planProfiles() {
	pairs, adds, omitted := matchProfiles(b.des.AgentProfiles, b.cur.AgentProfiles)
	for _, p := range adds {
		b.addProfile(p)
	}
	for _, pp := range pairs {
		b.changeProfile(pp)
	}
	for _, p := range omitted {
		if b.skip(profilePath(p)) {
			continue
		}
		b.notes = append(b.notes, fmt.Sprintf(r6NotDropped, p.Name, p.AgentType))
	}
}

// templateParameters is the parameters sp_add_agent_profile copies into a
// new profile of the type (state.Facts.TemplateProfileParameters, R6).
func (b *builder) templateParameters(agentType string) (map[string]string, bool) {
	if b.in.Facts == nil {
		return nil, false
	}
	out := map[string]string{}
	for _, p := range b.in.Facts.TemplateProfileParameters {
		if p.AgentType == agentType {
			out[p.Name] = p.Value
		}
	}
	return out, len(out) > 0
}

// addProfile: sp_add_agent_profile, then the parameter calls against the
// copied set (R6).
func (b *builder) addProfile(p *model.AgentProfile) {
	path := profilePath(p)
	tpl, ok := b.templateParameters(p.AgentType)
	if !ok {
		b.refuse(path, r6NoTemplate, p.AgentType)
		return
	}
	call, err := creationCall("sp_add_agent_profile", p, normalize.Context{Object: "profile"},
		[]Param{{Name: "@profile_id", Value: "@profile_id OUTPUT"}})
	if err != nil {
		b.refuse(path, "%v", err)
		return
	}
	call.Prologue = "DECLARE @profile_id int;"
	op := b.distOp(2, profileOrder(p)+"1", "profile", "add", path, call)
	if e, ok := cost.Lookup(cost.OpAddProfile, "", "transactional"); ok {
		withCites(&op, e)
	}
	op.Reason = "the file declares a profile that does not exist; it starts with the parameters of its type's template"
	op.Sources = append(op.Sources, "R6", "spec Order step 2")
	if p.Default != nil && *p.Default {
		// @default = 1 changes the profile every later agent of the type
		// takes (Task 14); any other new profile is used by nothing yet.
		b.markShared(&op)
	}
	b.add(op)
	// Parameters omitted: the template's set, which sp_add_agent_profile
	// has just copied, so no parameter call (final review item 5).
	b.profileParameters(p, p, path, tpl, true)
}

// changeProfile changes an existing profile: its description, and its
// parameters against its current ones (R6). A change of default is refused.
func (b *builder) changeProfile(pp pair[model.AgentProfile]) {
	path := pp.path("agent_profiles")
	if b.skip(path) {
		return
	}
	for _, ch := range b.diff(path, pp.Des, pp.Cur) {
		switch strings.TrimPrefix(ch.Pattern, "agent_profiles[*].") {
		case "default":
			b.refuse(ch.Path, "%s", r6Default)
		case "description":
			b.profileDescription(pp.Des, pp.Cur, ch)
		}
	}
	if !b.skip(path + ".parameters") {
		b.profileParameters(pp.Des, pp.Cur, path, pp.Cur.Parameters, false)
	}
}

// wantedParameters is the parameter set the file declares for p: its
// parameters, or the template's set when it omits them (nil,
// model.ProfileParameters); false, with a refusal, when that set is not
// known.
func (b *builder) wantedParameters(p *model.AgentProfile, path string) (map[string]string, bool) {
	if p.Parameters != nil {
		return p.Parameters, true
	}
	tpl, ok := b.templateParameters(p.AgentType)
	if !ok {
		b.refuse(path, r6NoTemplate, p.AgentType)
	}
	return tpl, ok
}

func (b *builder) profileDescription(d, c *model.AgentProfile, ch Change) {
	e, ok := lookupChange(ch)
	if !ok {
		b.unmeasured(ch)
		return
	}
	pro, err := profilePrologue(c)
	if err != nil {
		b.refuse(ch.Path, "%v", err)
		return
	}
	op := b.distOp(2, profileOrder(c)+"2", "profile_property", "change", profilePath(c), Call{
		Procedure: e.Procedure, Prologue: pro, Params: []Param{
			{Name: "@profile_id", Value: "@profile_id"},
			{Name: "@property", Value: literal(e.Property)},
			{Name: "@value", Value: literal(orEmpty(d.Description))},
		}})
	withCites(&op, e)
	op.Changes = []PropertyChange{{Path: ch.Path, Before: orEmpty(ch.Before), After: orEmpty(ch.After)}}
	op.Reason = "the profile's description changes"
	b.markShared(&op)
	b.add(op)
}

// profileParameters plans the parameters of the file's profile p
// (wantedParameters) against have, the set the profile holds before (the
// template's copy for a new one, its current parameters otherwise), names
// compared without regard to
// case: sp_change_agent_parameter per changed value, sp_add_agent_parameter
// per name have lacks, sp_drop_agent_parameter per name the file omits when
// PF.drop_parameter is measured (R6). A copied name is never added (20067),
// and a name the profile lacks never changed (it returns 0 and changes
// nothing, PF.change_missing_parameter). created tells a profile this plan
// creates, whose parameter calls are online only. The prologue finds the
// profile by stored's name: the current profile's for an existing one (minor
// 10 of the final review).
func (b *builder) profileParameters(p, stored *model.AgentProfile, path string, have map[string]string, created bool) {
	e, ok := cost.Lookup("agent_profiles[*].parameters", "", "transactional")
	if !ok {
		b.refuse(path+".parameters", "cost of agent_profiles[*].parameters change not measured")
		return
	}
	want, ok := b.wantedParameters(p, path)
	if !ok {
		return
	}
	pro, err := profilePrologue(stored)
	if err != nil {
		b.refuse(path, "%v", err)
		return
	}
	haveFold := map[string]string{} // lower-cased name to the name held
	for n := range have {
		haveFold[strings.ToLower(n)] = n
	}
	desFold := map[string]bool{}
	type call struct {
		proc, name, before, after string
		params                    []Param
	}
	var calls []call
	for _, n := range sortedNames(want) {
		v := want[n]
		desFold[strings.ToLower(n)] = true
		held, ok := haveFold[strings.ToLower(n)]
		switch {
		case !ok:
			calls = append(calls, call{"sp_add_agent_parameter", n, "", v, []Param{
				{Name: "@parameter_name", Value: literal(n)}, {Name: "@parameter_value", Value: literal(v)}}})
		case have[held] != v:
			calls = append(calls, call{"sp_change_agent_parameter", held, have[held], v, []Param{
				{Name: "@parameter_name", Value: literal(held)}, {Name: "@parameter_value", Value: literal(v)}}})
		}
	}
	if dropParameterMeasured() {
		for _, n := range sortedNames(have) {
			if !desFold[strings.ToLower(n)] {
				calls = append(calls, call{"sp_drop_agent_parameter", n, have[n], "", []Param{
					{Name: "@parameter_name", Value: literal(n)}}})
			}
		}
	}
	for _, c := range calls {
		cp := path + ".parameters" + model.Element(c.name)
		op := b.distOp(2, profileOrder(p)+"3"+sep+strings.ToLower(c.name), "profile_property", "change", path, Call{
			Procedure: c.proc, Prologue: pro, Params: append([]Param{{Name: "@profile_id", Value: "@profile_id"}}, c.params...)})
		withCites(&op, e)
		op.Changes = []PropertyChange{{Path: cp, Before: c.before, After: c.after}}
		op.Reason = fmt.Sprintf("the profile's parameter %s changes (R6)", c.name)
		op.Sources = append(op.Sources, "R6")
		if !created {
			// A profile the plan creates is used by nothing yet: its
			// parameters change no shared object (Task 16 review).
			b.markShared(&op)
		}
		b.add(op)
	}
}

func sortedNames(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}
