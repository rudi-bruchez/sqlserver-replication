package main

import (
	"database/sql"
	"errors"
	"net/url"
	"reflect"
	"sort"
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
		if q.Get("app name") != "sqlrepl" {
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

func TestServerFlags(t *testing.T) {
	f := serverFlags{}
	if err := f.Set("repllab=tcp:127.0.0.1,11980"); err != nil {
		t.Fatal(err)
	}
	e, ok := f.lookup("REPLLAB")
	if !ok || e.Address != "tcp:127.0.0.1,11980" || e.Name != "repllab" {
		t.Errorf("lookup(REPLLAB) = %+v, %v; want repllab at tcp:127.0.0.1,11980", e, ok)
	}

	f = serverFlags{}
	if err := f.Set("a=x"); err != nil {
		t.Fatal(err)
	}
	if err := f.Set("A=y"); err == nil {
		t.Error("a second entry for A was accepted")
	}
	for _, s := range []string{"=x", "a="} {
		if err := (serverFlags{}).Set(s); err == nil {
			t.Errorf("Set(%q) accepted", s)
		}
	}
}

func TestOpenSubscribers(t *testing.T) {
	f := serverFlags{}
	for _, s := range []string{"repllab=P", "other=Q"} {
		if err := f.Set(s); err != nil {
			t.Fatal(err)
		}
	}
	// The fake connections are never closed: Close on a zero sql.DB panics.
	var opened []string
	open := func(address string) (*sql.DB, error) {
		opened = append(opened, address)
		return new(sql.DB), nil
	}
	subs, err := openSubscribers(f, "P", "P", open)
	if err != nil {
		t.Fatal(err)
	}
	sort.Strings(opened)
	if want := []string{"P", "Q"}; !reflect.DeepEqual(opened, want) {
		t.Errorf("opened %q, want %q", opened, want)
	}
	var keys []string
	for k, db := range subs {
		keys = append(keys, k)
		if db == nil {
			t.Errorf("%s: nil connection", k)
		}
	}
	sort.Strings(keys)
	if want := []string{"other", "repllab"}; !reflect.DeepEqual(keys, want) {
		t.Errorf("keys %q, want %q", keys, want)
	}
	if subs["repllab"] == subs["other"] {
		t.Error("both entries share one connection")
	}

	failing := func(address string) (*sql.DB, error) {
		if address == "Q" {
			return nil, errors.New("refused")
		}
		return new(sql.DB), nil
	}
	if _, err := openSubscribers(f, "P", "P", failing); err == nil {
		t.Error("a failed connection was not reported")
	}
}
