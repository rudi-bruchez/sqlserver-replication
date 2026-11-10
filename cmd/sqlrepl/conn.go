package main

import (
	"fmt"
	"net/url"
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
