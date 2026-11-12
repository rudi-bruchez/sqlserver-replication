package model

import (
	"fmt"
	"reflect"
	"sort"
	"strings"
)

// Paths name an element of the model: the YAML keys joined by ".", a list
// element written [<Key()>] with "]" doubled inside the key, for example
// publications[SalesPub].subscriptions[REPLLAB/SalesSub].distribution_agent.run_as.

// Key returns the publication name.
func (p Publication) Key() string { return p.Name }

// Key returns the article name.
func (a Article) Key() string { return a.Name }

// Key returns the schedule name.
func (s Schedule) Key() string { return s.Name }

// Key returns <subscriber>/<database>.
func (s Subscription) Key() string { return s.Subscriber + "/" + s.Database }

// Key returns <subscriber>/<database>.
func (s SharedDistributionAgent) Key() string { return s.Subscriber + "/" + s.Database }

// Key returns <subscriber>/<database>.
func (s SharedPullAgent) Key() string { return s.Subscriber + "/" + s.Database }

// Key returns <agent_type>/<name>.
func (p AgentProfile) Key() string { return p.AgentType + "/" + p.Name }

// Element returns the path segment of a list element.
func Element(key string) string {
	return "[" + strings.ReplaceAll(key, "]", "]]") + "]"
}

// Join appends a YAML key to a path.
func Join(path, key string) string {
	if path == "" {
		return key
	}
	return path + "." + key
}

// Pattern replaces each bracketed element key of a path by "*":
// publications[P].articles[a]]b] gives publications[*].articles[*].
func Pattern(path string) string {
	var b strings.Builder
	for i := 0; i < len(path); i++ {
		if path[i] != '[' {
			b.WriteByte(path[i])
			continue
		}
		b.WriteString("[*]")
		for i++; i < len(path); i++ {
			if path[i] != ']' {
				continue
			}
			if i+1 < len(path) && path[i+1] == ']' {
				i++ // a doubled "]" inside the key
				continue
			}
			break
		}
	}
	return b.String()
}

// Step is one level of the walk above a struct: Value is a pointer to the
// enclosing struct (the outermost one when fields are inlined) and Key the
// YAML key followed out of it, without the element key of a list. The steps
// of a subscription's distribution agent are, from the root,
// {publications, *Config}, {subscriptions, *Publication},
// {distribution_agent, *Subscription}.
type Step struct {
	Key   string
	Value any
}

// omissible is implemented by the structs some of whose properties may be
// nil in a complete configuration. parents runs from the root to the
// struct's own parent; its last step names the key under which the struct
// hangs.
type omissible interface {
	OmittedOK(key string, parents []Step) bool
}

// NilProperties returns, sorted, the paths of every nil pointer property
// reachable from c, except those the enclosing struct allows to be omitted.
// Findings are not walked.
func NilProperties(c *Config) []string {
	var out []string
	root := reflect.ValueOf(c).Elem()
	walkStruct(root, "", nil, root, &out)
	sort.Strings(out)
	return out
}

var findingsType = reflect.TypeFor[[]Finding]()

// walkStruct walks the fields of sv. judge is the struct that answers
// OmittedOK for them: sv itself, or the outermost struct when sv is inlined.
// path is the path of judge and parents the steps above it.
func walkStruct(sv reflect.Value, path string, parents []Step, judge reflect.Value, out *[]string) {
	t := sv.Type()
	for i := range t.NumField() {
		f := t.Field(i)
		tag, ok := f.Tag.Lookup("yaml")
		if !f.IsExported() || !ok {
			continue
		}
		key, opts, _ := strings.Cut(tag, ",")
		if key == "-" || f.Type == findingsType {
			continue
		}
		fv := sv.Field(i)
		checkWalkable(t, f)
		if hasOption(opts, "inline") {
			walkStruct(fv, path, parents, judge, out)
			continue
		}
		if key == "" {
			key = strings.ToLower(f.Name)
		}
		p := Join(path, key)
		child := append(parents[:len(parents):len(parents)], Step{Key: key, Value: judge.Addr().Interface()})

		if fv.Kind() == reflect.Pointer {
			if fv.IsNil() {
				if !omittedOK(judge, key, parents) {
					*out = append(*out, p)
				}
				continue
			}
			fv = fv.Elem()
		}
		switch fv.Kind() {
		case reflect.Struct:
			walkStruct(fv, p, child, fv, out)
		case reflect.Slice:
			if fv.Type().Elem().Kind() != reflect.Struct {
				continue
			}
			for j := range fv.Len() {
				e := fv.Index(j)
				k, ok := e.Addr().Interface().(interface{ Key() string })
				if !ok {
					panic(fmt.Sprintf("model: %s has no Key method", e.Type()))
				}
				walkStruct(e, p+Element(k.Key()), child, e, out)
			}
		}
	}
}

// checkWalkable panics on a field the walk cannot judge, so that a later
// field of such a shape is not skipped in silence: an inline field that is not
// a struct, a list of pointers to structs, a map whose values are structs.
func checkWalkable(owner reflect.Type, f reflect.StructField) {
	ft := f.Type
	tag := f.Tag.Get("yaml")
	_, opts, _ := strings.Cut(tag, ",")
	if hasOption(opts, "inline") && ft.Kind() != reflect.Struct {
		panic(fmt.Sprintf("model: inline field %s.%s is not a struct", owner, f.Name))
	}
	if ft.Kind() == reflect.Pointer {
		ft = ft.Elem()
	}
	isStruct := func(t reflect.Type) bool {
		return t.Kind() == reflect.Struct || t.Kind() == reflect.Pointer && t.Elem().Kind() == reflect.Struct
	}
	switch ft.Kind() {
	case reflect.Slice:
		if e := ft.Elem(); e.Kind() == reflect.Pointer && isStruct(e) {
			panic(fmt.Sprintf("model: field %s.%s is a list of pointers to structs", owner, f.Name))
		}
	case reflect.Map:
		if isStruct(ft.Elem()) {
			panic(fmt.Sprintf("model: field %s.%s is a map of structs", owner, f.Name))
		}
	}
}

func hasOption(opts, name string) bool {
	for _, o := range strings.Split(opts, ",") {
		if o == name {
			return true
		}
	}
	return false
}

func omittedOK(judge reflect.Value, key string, parents []Step) bool {
	o, ok := judge.Addr().Interface().(omissible)
	return ok && o.OmittedOK(key, parents)
}

// OmittedOK: the login and password of a connection only apply to SQL Server
// authentication.
func (c Connection) OmittedOK(key string, parents []Step) bool {
	switch key {
	case "login", "password_secret":
		return c.Security != nil && *c.Security != "sql"
	}
	return false
}

// OmittedOK: the FTP settings are set only when the publication is enabled
// for internet.
func (s Snapshot) OmittedOK(key string, parents []Step) bool {
	return key == "ftp" && s.EnabledForInternet != nil && !*s.EnabledForInternet
}

// OmittedOK: the file sizes and the creation connection only serve to create
// the distribution database and are never read; no storage connection string
// is the default.
func (d Distributor) OmittedOK(key string, parents []Step) bool {
	switch key {
	case "data_file_size_mb", "log_file_size_mb", "creation_connection", "storage_connection_string_secret":
		return true
	}
	return false
}

var schemaOnlyTypes = map[string]bool{
	"proc_schema_only": true, "view_schema_only": true,
	"aggregate_schema_only": true, "func_schema_only": true,
}

// OmittedOK: a schema-only article has no table properties, and a nil filter
// or synchronization object is "none".
func (a Article) OmittedOK(key string, parents []Step) bool {
	switch key {
	case "insert_column_names", "parameterized", "commands", "fire_triggers_on_snapshot":
		return a.Type != nil && schemaOnlyTypes[*a.Type]
	case "filter", "sync_object":
		return true
	}
	return false
}

var callModes = map[string]bool{"CALL": true, "SCALL": true, "MCALL": true, "XCALL": true}

// OmittedOK: only the CALL family of commands names a procedure.
func (c Command) OmittedOK(key string, parents []Step) bool {
	return key == "procedure" && !callModes[c.Mode]
}

// OmittedOK: a push subscription has no pull agent, a pull subscription has
// no push distribution agent, and a subscription of a publication without an
// independent agent uses the shared agent (push or pull) of its subscriber
// database. The backup and the LSN only serve the creation call and are
// never read.
func (s Subscription) OmittedOK(key string, parents []Step) bool {
	switch key {
	case "backup", "lsn":
		return true
	case "pull_agent":
		if s.Type != nil && *s.Type == "push" {
			return true
		}
		if s.Type == nil || *s.Type != "pull" {
			return false
		}
	case "distribution_agent":
		if s.Type != nil && *s.Type == "pull" {
			return true
		}
	default:
		return false
	}
	for i := len(parents) - 1; i >= 0; i-- {
		if p, ok := parents[i].Value.(*Publication); ok {
			return p.IndependentAgent != nil && !*p.IndependentAgent
		}
	}
	return false
}

// OmittedOK: a database with no publication needs no log reader agent.
func (p Publisher) OmittedOK(key string, parents []Step) bool {
	if key != "log_reader_agent" || len(parents) == 0 {
		return false
	}
	c, ok := parents[0].Value.(*Config)
	return ok && len(c.Publications) == 0
}

// OmittedOK: no job login has no password secret, and only the snapshot and
// pull agents have a distributor connection. The structs that inline an Agent
// delegate to it.
func (a Agent) OmittedOK(key string, parents []Step) bool {
	switch key {
	case "job_password_secret":
		return a.JobLogin == nil || *a.JobLogin == ""
	case "distributor_connection":
		if len(parents) == 0 {
			return true
		}
		k := parents[len(parents)-1].Key
		return k != "snapshot_agent" && k != "pull_agent" && k != "shared_pull_agents"
	}
	return false
}

// OmittedOK answers for the fields of the inlined Agent too.
func (d DistributionAgent) OmittedOK(key string, parents []Step) bool {
	return d.Agent.OmittedOK(key, parents)
}

// OmittedOK answers for the fields of the inlined DistributionAgent and
// Agent: a pull agent has no property of its own that may be omitted.
func (p PullAgent) OmittedOK(key string, parents []Step) bool {
	return p.DistributionAgent.OmittedOK(key, parents)
}

// OmittedOK answers for the fields of the inlined PullAgent.
func (s SharedPullAgent) OmittedOK(key string, parents []Step) bool {
	return s.PullAgent.OmittedOK(key, parents)
}
