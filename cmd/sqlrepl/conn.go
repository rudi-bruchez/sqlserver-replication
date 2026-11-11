package main

import (
	"database/sql"
	"fmt"
	"net/url"
	"sort"
	"strings"
)

// connParams holds what is needed to build a go-mssqldb connection URL.
type connParams struct {
	User     string
	Password string
	Extra    map[string]string // additional URL parameters, e.g. encrypt=disable
}

// protocols are the server name prefixes go-mssqldb understands.
var protocols = map[string]bool{"tcp": true, "np": true, "lpc": true, "admin": true}

// dsn builds a sqlserver:// URL for server, which can be "host",
// "host\instance", "host,port" or "host\instance,port", optionally prefixed
// by a protocol ("lpc:host\instance"). Without a user, the driver uses Windows
// integrated authentication.
func dsn(server, database string, p connParams) (string, error) {
	if server == "" {
		return "", fmt.Errorf("empty server name")
	}
	protocol := ""
	if proto, rest, ok := strings.Cut(server, ":"); ok && protocols[strings.ToLower(proto)] {
		protocol, server = strings.ToLower(proto), rest
	}
	host, port, _ := strings.Cut(server, ",")
	host, instance, _ := strings.Cut(host, `\`)
	if port != "" {
		host += ":" + port
	}
	u := url.URL{Scheme: "sqlserver", Host: host}
	if instance != "" {
		u.Path = "/" + instance
	}
	if p.User != "" {
		u.User = url.UserPassword(p.User, p.Password)
	}
	q := url.Values{}
	q.Set("app name", "sqlrepl")
	if database != "" {
		q.Set("database", database)
	}
	if protocol != "" {
		q.Set("protocol", protocol)
	}
	for k, v := range p.Extra {
		q.Set(k, v)
	}
	u.RawQuery = q.Encode()
	return u.String(), nil
}

// serverEntry is one -server NAME=ADDRESS flag, the name kept as typed.
type serverEntry struct {
	Name, Address string
}

// serverFlags collects repeated -server NAME=ADDRESS flags, keyed by the
// upper-case name: server names do not depend on case.
type serverFlags map[string]serverEntry

func (f serverFlags) String() string { return "" }

func (f serverFlags) Set(s string) error {
	name, address, ok := strings.Cut(s, "=")
	name, address = strings.TrimSpace(name), strings.TrimSpace(address)
	if !ok || name == "" || address == "" {
		return fmt.Errorf("expected NAME=ADDRESS, got %q", s)
	}
	k := strings.ToUpper(name)
	if _, dup := f[k]; dup {
		return fmt.Errorf("server %s given twice", name)
	}
	f[k] = serverEntry{Name: name, Address: address}
	return nil
}

// lookup finds the entry of a server name, whatever its case.
func (f serverFlags) lookup(name string) (serverEntry, bool) {
	e, ok := f[strings.ToUpper(name)]
	return e, ok
}

// openSubscribers opens every -server entry, to master, keyed by the name as
// typed. An entry whose address is the publisher's or the distributor's is
// opened too: an instance can be its own subscriber, and skipping it would
// leave every pull subscription unreadable. publisher and distributor are
// taken so that the caller filters nothing itself. On a failure it returns
// the error and the connections opened so far, which the caller closes.
func openSubscribers(flags serverFlags, publisher, distributor string, open func(address string) (*sql.DB, error)) (map[string]*sql.DB, error) {
	keys := make([]string, 0, len(flags))
	for k := range flags {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	subs := map[string]*sql.DB{}
	for _, k := range keys {
		e := flags[k]
		db, err := open(e.Address)
		if err != nil {
			return subs, fmt.Errorf("server %s: %w", e.Name, err)
		}
		subs[e.Name] = db
	}
	return subs, nil
}
