package model

import "strings"

// SecretName builds the name of the environment variable that provides a
// secret at apply time: SQLREPL_<kind>, then one _<part> per part. Each part
// is upper-cased and every character outside A-Z and 0-9 becomes "_".
func SecretName(kind string, parts ...string) string {
	var b strings.Builder
	b.WriteString("SQLREPL_")
	b.WriteString(kind)
	for _, p := range parts {
		b.WriteByte('_')
		b.WriteString(sanitize(p))
	}
	return b.String()
}

func sanitize(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'a' && c <= 'z':
			c -= 'a' - 'A'
		case c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		default:
			c = '_'
		}
		b.WriteByte(c)
	}
	return b.String()
}
