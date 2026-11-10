package main

import (
	"net/url"
	"testing"
)

func TestDSN(t *testing.T) {
	cases := []struct {
		server, database string
		p                connParams
		host, path, user string
		query            map[string]string
	}{
		{"srv", "Sales", connParams{}, "srv", "", "", map[string]string{"database": "Sales"}},
		{`srv\INST`, "", connParams{}, "srv", "/INST", "", map[string]string{}},
		{"srv,14330", "", connParams{}, "srv:14330", "", "", map[string]string{}},
		{`lpc:localhost\SQLEXPRESS`, "", connParams{}, "localhost", "/SQLEXPRESS", "", map[string]string{"protocol": "lpc"}},
		{`srv\INST,14330`, "db", connParams{User: "u", Password: "p@ss;word", Extra: map[string]string{"encrypt": "disable"}},
			"srv:14330", "/INST", "u", map[string]string{"database": "db", "encrypt": "disable"}},
	}
	for _, c := range cases {
		s, err := dsn(c.server, c.database, c.p)
		if err != nil {
			t.Fatal(err)
		}
		u, err := url.Parse(s)
		if err != nil {
			t.Fatalf("%s: %v", s, err)
		}
		if u.Scheme != "sqlserver" || u.Host != c.host || u.Path != c.path {
			t.Errorf("%s: host %q path %q", s, u.Host, u.Path)
		}
		if u.User.Username() != c.user {
			t.Errorf("%s: user %q", s, u.User.Username())
		}
		if pw, _ := u.User.Password(); pw != c.p.Password {
			t.Errorf("%s: password not preserved", s)
		}
		q := u.Query()
		if q.Get("app name") != "replcfg" {
			t.Errorf("%s: missing app name", s)
		}
		for k, v := range c.query {
			if q.Get(k) != v {
				t.Errorf("%s: %s = %q, want %q", s, k, q.Get(k), v)
			}
		}
	}
	if _, err := dsn("", "", connParams{}); err == nil {
		t.Fatal("expected an error for an empty server")
	}
}
