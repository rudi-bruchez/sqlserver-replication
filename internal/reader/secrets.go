package reader

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
)

// secrets gives each source of a secret its environment variable name. Two
// sources whose parts differ only by case or by characters that sanitizing
// replaces share a name when their upper-cased parts are equal (the same
// source under two spellings), and get distinct names otherwise.
type secrets struct {
	byRaw  map[string]string // raw key -> name
	source map[string]string // name -> first source, for messages
}

// name returns the name for a source. The finding is a note, without path,
// when the sanitized name was already given to another source; the name is
// then suffixed _2, _3 in order.
func (s *secrets) name(kind string, parts ...string) (string, *model.Finding) {
	if s.byRaw == nil {
		s.byRaw, s.source = map[string]string{}, map[string]string{}
	}
	up := make([]string, 0, len(parts)+1)
	up = append(up, strings.ToUpper(kind))
	for _, p := range parts {
		up = append(up, strings.ToUpper(p))
	}
	raw := strings.Join(up, "\x00")
	if n, ok := s.byRaw[raw]; ok {
		return n, nil
	}
	desc := kind + " " + strings.Join(parts, "/")
	base := model.SecretName(kind, parts...)
	n := base
	for i := 2; s.source[n] != ""; i++ {
		n = base + "_" + strconv.Itoa(i)
	}
	s.byRaw[raw], s.source[n] = n, desc
	if n == base {
		return n, nil
	}
	return n, &model.Finding{
		Kind:    model.FindingNote,
		Message: fmt.Sprintf("secret name %s is already used by %s; %s uses %s", base, s.source[base], desc, n),
	}
}
