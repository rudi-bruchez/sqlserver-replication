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

// ASCIIUpper upper-cases the ASCII letters of s and leaves every other
// character as it is: no Unicode case mapping, so that "ı" and "I" differ.
func ASCIIUpper(s string) string {
	var b strings.Builder
	for _, r := range s {
		if r >= 'a' && r <= 'z' {
			r -= 'a' - 'A'
		}
		b.WriteRune(r)
	}
	return b.String()
}

// sanitize upper-cases ASCII letters and replaces each character (not each
// byte) outside A-Z and 0-9 with one "_".
func sanitize(s string) string {
	var b strings.Builder
	for _, r := range ASCIIUpper(s) {
		if r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' {
			b.WriteRune(r)
		} else {
			b.WriteByte('_')
		}
	}
	return b.String()
}
