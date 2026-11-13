package apply

import (
	"database/sql"
	"errors"
	"sort"
	"strings"

	mssql "github.com/microsoft/go-mssqldb"

	"github.com/rudi-bruchez/sqlserver-replication/internal/decode"
	"github.com/rudi-bruchez/sqlserver-replication/internal/plan"
)

// class is what apply does with a refused statement (R47).
type class int

const (
	classOther        class = iota // a failure
	classBusy                      // 22022, the job is running or has a pending request
	classAgentStopped              // 22022, SQL Server Agent is not running (R56)
	classGenerating                // 21854, 21861: a snapshot is being generated
	classLogReader                 // 18752, tolerated on the procedures of effectQuery only
	classDeadlock                  // 1205
)

// The 22022 wordings (Task 2, lab/README.md "SQL Server Agent stopped"):
// both the busy texts and the Agent-stopped text contain "running", so the
// stopped one is matched on its whole phrase.
const (
	agentStoppedWording = "SQLServerAgent is not currently running"
	busyRunningWording  = "already running"
	busyPendingWording  = "already has a pending request"
)

// classify returns the class of a driver error and its number (0 for an
// error that is not an mssql.Error). A 22022 with neither the busy nor the
// stopped wording is classOther: no measurement says it can be waited out.
func classify(err error) (class, int) {
	var e mssql.Error
	if !errors.As(err, &e) {
		var pe *mssql.Error
		if !errors.As(err, &pe) || pe == nil {
			return classOther, 0
		}
		e = *pe
	}
	n := int(e.Number)
	switch n {
	case 22022:
		switch {
		case strings.Contains(e.Message, agentStoppedWording):
			return classAgentStopped, n
		case strings.Contains(e.Message, busyRunningWording), strings.Contains(e.Message, busyPendingWording):
			return classBusy, n
		}
		return classOther, n
	case 21854, 21861:
		return classGenerating, n
	case 18752:
		return classLogReader, n
	case 1205:
		return classDeadlock, n
	}
	return classOther, n
}

// retryDecision tells whether a statement refused with 21854 or 21861 is
// run once more after the snapshot job is idle (R47): when the snapshot is
// not ready, or when the call passes @force_invalidate_snapshot = 1.
func retryDecision(passesInvalidateFlag, ready bool) bool {
	return passesInvalidateFlag || !ready
}

// Parameter values of the plan's calls are T-SQL literals (plan.Param).

// unliteral decodes N'...' (or '...'): ok false for anything else, NULL
// included.
func unliteral(v string) (string, bool) {
	s := strings.TrimSpace(v)
	switch {
	case strings.HasPrefix(s, "N'") && strings.HasSuffix(s, "'") && len(s) >= 3:
		s = s[2 : len(s)-1]
	case strings.HasPrefix(s, "'") && strings.HasSuffix(s, "'") && len(s) >= 2:
		s = s[1 : len(s)-1]
	default:
		return "", false
	}
	return strings.ReplaceAll(s, "''", "'"), true
}

func isNull(v string) bool { return strings.EqualFold(strings.TrimSpace(v), "NULL") }

func param(op plan.Operation, name string) (string, bool) {
	for _, p := range op.Call.Params {
		if strings.EqualFold(p.Name, name) {
			return p.Value, true
		}
	}
	return "", false
}

func stringParam(op plan.Operation, name string) (string, bool) {
	v, ok := param(op, name)
	if !ok {
		return "", false
	}
	return unliteral(v)
}

// The re-reads of R47. Each returns one row, one int: 1 when the call's
// effect is in place, 0 otherwise. They run in the operation's database.
const (
	reReadDropped     = "SELECT CASE WHEN EXISTS (SELECT 1 FROM dbo.syspublications WHERE name = @publication) THEN 0 ELSE 1 END;"
	reReadUnpublished = "SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.databases WHERE name = @dbname AND is_published = 0) THEN 1 ELSE 0 END;"
	reReadSyncMethod  = "SELECT CASE WHEN EXISTS (SELECT 1 FROM dbo.syspublications WHERE name = @publication AND sync_method = @sync_method) THEN 1 ELSE 0 END;"
	reReadFilter      = "SELECT CASE WHEN EXISTS (SELECT 1 FROM dbo.sysarticles AS a JOIN dbo.syspublications AS p ON p.pubid = a.pubid" +
		" WHERE p.name = @publication AND a.name = @article AND CAST(a.filter_clause AS nvarchar(max)) = @filter_clause" +
		" AND EXISTS (SELECT 1 FROM sys.objects AS o WHERE o.object_id = a.filter)) THEN 1 ELSE 0 END;"
	reReadNoFilter = "SELECT CASE WHEN EXISTS (SELECT 1 FROM dbo.sysarticles AS a JOIN dbo.syspublications AS p ON p.pubid = a.pubid" +
		" WHERE p.name = @publication AND a.name = @article AND a.filter_clause IS NULL" +
		" AND NOT EXISTS (SELECT 1 FROM sys.objects AS o WHERE o.object_id = a.filter)) THEN 1 ELSE 0 END;"
)

// effectQuery is the re-read that tells whether a call refused with 18752
// did its work all the same (R47), for the four measured procedures only:
// sp_droppublication, sp_replicationdboption publish false,
// sp_changepublication sync_method and sp_articlefilter with the reinit
// flag. Every other operation has none, and 18752 there is a failure.
func effectQuery(op plan.Operation) (query string, args []any, ok bool) {
	switch op.Call.Procedure {
	case "sp_droppublication":
		pub, ok := stringParam(op, "@publication")
		if !ok {
			return "", nil, false
		}
		return reReadDropped, []any{sql.Named("publication", pub)}, true
	case "sp_replicationdboption":
		db, ok1 := stringParam(op, "@dbname")
		opt, ok2 := stringParam(op, "@optname")
		val, ok3 := stringParam(op, "@value")
		if !ok1 || !ok2 || !ok3 || !strings.EqualFold(opt, "publish") || !strings.EqualFold(val, "false") {
			return "", nil, false
		}
		return reReadUnpublished, []any{sql.Named("dbname", db)}, true
	case "sp_changepublication":
		pub, ok1 := stringParam(op, "@publication")
		prop, ok2 := stringParam(op, "@property")
		val, ok3 := stringParam(op, "@value")
		if !ok1 || !ok2 || !ok3 || !strings.EqualFold(prop, "sync_method") {
			return "", nil, false
		}
		code, err := decode.SyncMethodCode(strings.ReplaceAll(strings.ToLower(val), " ", "_"))
		if err != nil {
			return "", nil, false
		}
		return reReadSyncMethod, []any{sql.Named("publication", pub), sql.Named("sync_method", code)}, true
	case "sp_articlefilter":
		if v, ok := param(op, "@force_reinit_subscription"); !ok || (v != "1" && !strings.EqualFold(v, "true")) {
			return "", nil, false
		}
		pub, ok1 := stringParam(op, "@publication")
		art, ok2 := stringParam(op, "@article")
		if !ok1 || !ok2 {
			return "", nil, false
		}
		v, present := param(op, "@filter_clause")
		if !present || isNull(v) {
			return reReadNoFilter, []any{sql.Named("publication", pub), sql.Named("article", art)}, true
		}
		clause, ok := unliteral(v)
		if !ok {
			return "", nil, false
		}
		return reReadFilter, []any{sql.Named("publication", pub), sql.Named("article", art), sql.Named("filter_clause", clause)}, true
	}
	return "", nil, false
}

// secretArgs binds every secret of a statement (R46): sql.Named of the
// variable without its @, the value the secret function returns for the
// name. A secret it does not return is an error that names the variable
// only, never a value.
func secretArgs(st plan.Statement, secret func(string) (string, bool)) ([]any, error) {
	args := make([]any, 0, len(st.Secrets))
	for _, v := range st.Secrets {
		value, ok := secret(v.Name)
		if !ok {
			return nil, errors.New("secret " + v.Name + " is not set")
		}
		args = append(args, sql.Named(strings.TrimPrefix(v.Var, "@"), value))
	}
	return args, nil
}

// mask replaces every occurrence of every value in a message with ****
// (R53): server messages can echo a bound value (Msg 245, panel M). The
// longer values go first, so that a value containing another is masked
// whole; empty values are skipped.
func mask(message string, values []string) string {
	vs := make([]string, 0, len(values))
	for _, v := range values {
		if v != "" {
			vs = append(vs, v)
		}
	}
	sort.Slice(vs, func(i, j int) bool { return len(vs[i]) > len(vs[j]) })
	for _, v := range vs {
		message = strings.ReplaceAll(message, v, "****")
	}
	return message
}
