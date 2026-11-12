package reader

import (
	"fmt"
	"slices"
	"strings"
)

// checkSyncView compares the definition of an article's synchronization view
// with the article's filter clause and published columns. generated is false
// when the definition is not in the form sp_articleview writes, which means a
// user's own view: it cannot be checked and raises no problem. Otherwise
// problems lists the mismatches, and is empty when the view matches.
//
// The form is, on one line,
//
//	create view [s].[v]as select [c1],[c2]  from  [s].[t]  where HAS_PERMS_BY_NAME('[s].[t]', 'OBJECT', 'SELECT')= 1  and (<clause>)
//
// with no "and (<clause>)" when the article has no clause. The text is read
// by position, one pass: a clause can contain "= 1", and a bracketed name can
// contain " from " or ",".
func checkSyncView(definition, clause string, columns []string) (generated bool, problems []string) {
	sc := &scanner{s: definition}
	cols, rest, ok := sc.header()
	if !ok {
		return false, nil
	}
	if !slices.Equal(cols, columns) {
		problems = append(problems, fmt.Sprintf("view columns %v, article columns %v", cols, columns))
	}
	view := normalizeSQL(rest)
	want := ""
	if clause != "" {
		want = normalizeSQL(clause)
	}
	got := ""
	if view != "" {
		got = view
		if inner, ok := guardedClause(rest); ok {
			got = inner
		}
	}
	if got != want {
		problems = append(problems, fmt.Sprintf("view filter %q, article clause %q", got, clause))
	}
	return true, problems
}

// guardedClause returns the normalized clause of "and (<clause>)", the text
// that follows the permission guard.
func guardedClause(rest string) (string, bool) {
	sc := &scanner{s: rest}
	sc.skipSpace()
	if !sc.keyword("and") {
		return "", false
	}
	sc.skipSpace()
	t := strings.TrimRight(rest[sc.p:], " \t\r\n")
	// A hand-altered view can end in ");".
	t = strings.TrimRight(strings.TrimSuffix(t, ";"), " \t\r\n")
	if len(t) < 2 || t[0] != '(' || t[len(t)-1] != ')' {
		return "", false
	}
	return normalizeSQL(t[1 : len(t)-1]), true
}

type scanner struct {
	s string
	p int
}

func (sc *scanner) skipSpace() {
	for sc.p < len(sc.s) && isSpace(sc.s[sc.p]) {
		sc.p++
	}
}

func isSpace(c byte) bool { return c == ' ' || c == '\t' || c == '\r' || c == '\n' }

func isWordByte(c byte) bool {
	return c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' ||
		c == '_' || c == '@' || c == '#' || c == '$'
}

// keyword consumes the word w (any case) when it stands alone at the
// position, that is when it is not followed by another word character.
func (sc *scanner) keyword(w string) bool {
	end := sc.p + len(w)
	if end > len(sc.s) || !strings.EqualFold(sc.s[sc.p:end], w) {
		return false
	}
	if end < len(sc.s) && isWordByte(sc.s[end]) {
		return false
	}
	sc.p = end
	return true
}

func (sc *scanner) char(c byte) bool {
	if sc.p < len(sc.s) && sc.s[sc.p] == c {
		sc.p++
		return true
	}
	return false
}

// bracketed reads [name], with ]] for a closing bracket in the name, and
// returns the name unquoted.
func (sc *scanner) bracketed() (string, bool) {
	if !sc.char('[') {
		return "", false
	}
	var b strings.Builder
	for sc.p < len(sc.s) {
		c := sc.s[sc.p]
		sc.p++
		if c == ']' {
			if sc.p < len(sc.s) && sc.s[sc.p] == ']' {
				sc.p++
				b.WriteByte(']')
				continue
			}
			return b.String(), true
		}
		b.WriteByte(c)
	}
	return "", false
}

// literal reads '...', with ” for a quote in the text.
func (sc *scanner) literal() (string, bool) {
	if !sc.char('\'') {
		return "", false
	}
	var b strings.Builder
	for sc.p < len(sc.s) {
		c := sc.s[sc.p]
		sc.p++
		if c == '\'' {
			if sc.p < len(sc.s) && sc.s[sc.p] == '\'' {
				sc.p++
				b.WriteByte('\'')
				continue
			}
			return b.String(), true
		}
		b.WriteByte(c)
	}
	return "", false
}

// objectName reads [a].[b] (one to three parts).
func (sc *scanner) objectName() bool {
	for i := 0; i < 3; i++ {
		if _, ok := sc.bracketed(); !ok {
			return false
		}
		sc.skipSpace()
		if !sc.char('.') {
			return true
		}
		sc.skipSpace()
	}
	return false
}

// header reads "create view <name> as select <columns> from <table> where
// <guard>" and returns the unquoted column names and the text after the
// guard.
func (sc *scanner) header() (cols []string, rest string, ok bool) {
	sc.skipSpace()
	if !sc.keyword("create") {
		return nil, "", false
	}
	sc.skipSpace()
	if !sc.keyword("view") {
		return nil, "", false
	}
	sc.skipSpace()
	if !sc.objectName() {
		return nil, "", false
	}
	sc.skipSpace()
	if !sc.keyword("as") {
		return nil, "", false
	}
	sc.skipSpace()
	if !sc.keyword("select") {
		return nil, "", false
	}
	for {
		sc.skipSpace()
		name, ok := sc.bracketed()
		if !ok {
			return nil, "", false
		}
		cols = append(cols, name)
		sc.skipSpace()
		if sc.char(',') {
			continue
		}
		if sc.keyword("from") {
			break
		}
		return nil, "", false
	}
	// The table part, up to the where keyword: skip bracketed names and
	// literals whole, so that a "where" inside a name is not the keyword.
	sc.skipSpace()
	start := sc.p
	for {
		if sc.p >= len(sc.s) {
			return nil, "", false
		}
		c := sc.s[sc.p]
		switch {
		case c == '[':
			if _, ok := sc.bracketed(); !ok {
				return nil, "", false
			}
		case c == '\'':
			if _, ok := sc.literal(); !ok {
				return nil, "", false
			}
		case isWordByte(c) && (sc.p == 0 || !isWordByte(sc.s[sc.p-1])) && sc.keyword("where"):
			if strings.TrimSpace(sc.s[start:sc.p-len("where")]) == "" {
				return nil, "", false
			}
			goto guard
		default:
			sc.p++
		}
	}
guard:
	sc.skipSpace()
	if !sc.keyword("HAS_PERMS_BY_NAME") {
		return nil, "", false
	}
	sc.skipSpace()
	if !sc.char('(') {
		return nil, "", false
	}
	for i, want := range []string{"", "OBJECT", "SELECT"} {
		sc.skipSpace()
		v, ok := sc.literal()
		if !ok || (want != "" && v != want) {
			return nil, "", false
		}
		sc.skipSpace()
		if i < 2 {
			if !sc.char(',') {
				return nil, "", false
			}
		}
	}
	if !sc.char(')') {
		return nil, "", false
	}
	sc.skipSpace()
	if !sc.char('=') {
		return nil, "", false
	}
	sc.skipSpace()
	if !sc.char('1') || (sc.p < len(sc.s) && isWordByte(sc.s[sc.p])) {
		return nil, "", false
	}
	return cols, sc.s[sc.p:], true
}

// normalizeSQL collapses every run of white space to one space and trims the
// ends, outside '...' literals and [...] identifiers, which are kept as they
// are: 'New  York' and 'New York' differ.
func normalizeSQL(s string) string {
	var b strings.Builder
	space := false
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case isSpace(c):
			space = true
			continue
		case c == '\'' || c == '[':
			if space && b.Len() > 0 {
				b.WriteByte(' ')
			}
			space = false
			b.WriteByte(c)
			closer := byte('\'')
			if c == '[' {
				closer = ']'
			}
			for i++; i < len(s); i++ {
				b.WriteByte(s[i])
				if s[i] == closer {
					if i+1 < len(s) && s[i+1] == closer {
						i++
						b.WriteByte(closer)
						continue
					}
					break
				}
			}
			continue
		}
		if space && b.Len() > 0 {
			b.WriteByte(' ')
		}
		space = false
		b.WriteByte(c)
	}
	return b.String()
}
