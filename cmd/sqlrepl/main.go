// Command sqlrepl manages the configuration of SQL Server transactional
// replication as a declarative file.
//
// Only the export is implemented: it reads a publication database, its
// publications, articles, push and pull subscriptions and agents, and writes
// them as YAML, and on request the observed runtime facts as JSON. It runs
// SELECT statements only.
package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	_ "github.com/microsoft/go-mssqldb"
	_ "github.com/microsoft/go-mssqldb/namedpipe"
	_ "github.com/microsoft/go-mssqldb/sharedmemory"

	"github.com/rudi-bruchez/sqlserver-replication/internal/model"
	"github.com/rudi-bruchez/sqlserver-replication/internal/reader"
)

const usage = `sqlrepl manages SQL Server transactional replication as a declarative file.

Usage:
  sqlrepl export -publisher SERVER -database DB [options]

Run "sqlrepl export -h" for the export options.
`

func main() {
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "export":
		err = runExport(os.Args[2:], os.Stdout)
	case "-h", "-help", "--help", "help":
		fmt.Print(usage)
		return
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n\n%s", os.Args[1], usage)
		os.Exit(2)
	}
	if err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return
		}
		fmt.Fprintln(os.Stderr, "sqlrepl:", err)
		os.Exit(1)
	}
}

// paramFlags collects repeated -param key=value flags.
type paramFlags map[string]string

func (p paramFlags) String() string { return "" }

func (p paramFlags) Set(s string) error {
	k, v, ok := strings.Cut(s, "=")
	if !ok || k == "" {
		return fmt.Errorf("expected key=value, got %q", s)
	}
	p[k] = v
	return nil
}

func runExport(args []string, stdout io.Writer) error {
	fs := flag.NewFlagSet("export", flag.ContinueOnError)
	publisher := fs.String("publisher", "", "publisher instance (host, host\\instance, host,port)")
	database := fs.String("database", "", "publication database")
	distributor := fs.String("distributor", "", "distributor instance (default: the distributor registered at the publisher)")
	publisherName := fs.String("publisher-name", "", "publisher name registered at the distributor (default: @@SERVERNAME of the publisher)")
	user := fs.String("user", "", "SQL Server login; the password is read from SQLREPL_PASSWORD (default: Windows authentication)")
	output := fs.String("o", "", "output file (default: standard output)")
	factsPath := fs.String("facts", "", "also write the observed runtime facts (snapshot, subscription and agent state) as JSON to this file")
	timeout := fs.Duration("timeout", 2*time.Minute, "overall timeout")
	params := paramFlags{}
	fs.Var(params, "param", "extra connection parameter key=value, repeatable (e.g. -param encrypt=disable)")
	servers := serverFlags{}
	fs.Var(servers, "server", "address of a server by name, NAME=ADDRESS, repeatable: a subscriber whose pull subscriptions are read, or the distributor")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *publisher == "" || *database == "" {
		fs.Usage()
		return fmt.Errorf("-publisher and -database are required")
	}

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()

	cp := connParams{User: *user, Password: os.Getenv("SQLREPL_PASSWORD"), Extra: params}
	// The probe runs on master: a connection to an offline or restoring
	// publication database fails before any query.
	master, err := open(ctx, *publisher, "master", cp)
	if err != nil {
		return fmt.Errorf("publisher: %w", err)
	}
	defer master.Close()
	probe, err := reader.Probe(ctx, master, *database)
	if err != nil {
		return err
	}
	if _, _, err := probe.Start(); err != nil {
		return err
	}
	// The stored name, in its own case, from here on.
	*database = probe.Name
	pub, err := open(ctx, *publisher, *database, cp)
	if err != nil {
		return fmt.Errorf("publisher: %w", err)
	}
	defer pub.Close()

	if *distributor == "" {
		*distributor = probe.Distributor
		if e, ok := servers.lookup(probe.Distributor); ok {
			*distributor = e.Address
		}
	}
	var dist *sql.DB
	if *distributor != "" {
		dist, err = open(ctx, *distributor, "", cp)
		if err != nil {
			return fmt.Errorf("distributor: %w", err)
		}
		defer dist.Close()
	}

	subs, err := openSubscribers(servers, *publisher, *distributor, func(address string) (*sql.DB, error) {
		return open(ctx, address, "master", cp)
	})
	defer func() {
		for _, db := range subs {
			db.Close()
		}
	}()
	if err != nil {
		return fmt.Errorf("subscriber: %w", err)
	}

	res, err := reader.Read(ctx, reader.Source{
		Publisher:     pub,
		Distributor:   dist,
		Database:      *database,
		PublisherName: *publisherName,
		Probe:         probe,
		Subscribers:   subs,
		Facts:         *factsPath != "",
	})
	if err != nil {
		return err
	}
	cfg := res.Config

	out, err := model.Marshal(cfg)
	if err != nil {
		return err
	}
	for _, f := range cfg.Findings {
		fmt.Fprintf(os.Stderr, "finding: %s: %s: %s\n", f.Kind, f.Path, f.Message)
	}
	var facts []byte
	if *factsPath != "" {
		// The observed runtime facts, as indented JSON: what the planner
		// needs beside the configuration, never part of it.
		b, err := json.MarshalIndent(res.Facts, "", "  ")
		if err != nil {
			return err
		}
		facts = append(b, '\n')
	}
	return writeOutputs(stdout, *output, out, *factsPath, facts)
}

// writeOutputs writes the YAML to output (stdout when empty) and the facts
// to factsPath when it is set. Both files are opened before either is
// written, so that a path that cannot be written fails the export before it
// writes anything: a file opened for nothing is closed untouched, and
// removed when the export created it.
func writeOutputs(stdout io.Writer, output string, yaml []byte, factsPath string, facts []byte) error {
	type target struct {
		path    string
		data    []byte
		f       *os.File
		created bool
	}
	var ts []*target
	if output != "" {
		ts = append(ts, &target{path: output, data: yaml})
	}
	if factsPath != "" {
		ts = append(ts, &target{path: factsPath, data: facts})
	}
	release := func() {
		for _, t := range ts {
			if t.f != nil {
				t.f.Close()
				if t.created {
					os.Remove(t.path)
				}
			}
		}
	}
	for _, t := range ts {
		_, statErr := os.Stat(t.path)
		f, err := os.OpenFile(t.path, os.O_WRONLY|os.O_CREATE, 0o644)
		if err != nil {
			release()
			return err
		}
		t.f, t.created = f, os.IsNotExist(statErr)
	}
	if output == "" {
		if _, err := stdout.Write(yaml); err != nil {
			release()
			return err
		}
	}
	var first error
	for _, t := range ts {
		// A device (/dev/null, /dev/stdout) cannot be truncated: only a
		// regular file is.
		var err error
		if fi, serr := t.f.Stat(); serr != nil {
			err = serr
		} else if fi.Mode().IsRegular() {
			err = t.f.Truncate(0)
		}
		if err == nil {
			_, err = t.f.Write(t.data)
		}
		if cerr := t.f.Close(); err == nil {
			err = cerr
		}
		t.f = nil
		if err != nil && first == nil {
			first = fmt.Errorf("writing %s: %w", t.path, err)
		}
	}
	return first
}

func open(ctx context.Context, server, database string, cp connParams) (*sql.DB, error) {
	d, err := dsn(server, database, cp)
	if err != nil {
		return nil, err
	}
	db, err := sql.Open("sqlserver", d)
	if err != nil {
		return nil, err
	}
	if err := db.PingContext(ctx); err != nil {
		db.Close()
		return nil, fmt.Errorf("connecting to %s: %w", server, err)
	}
	return db, nil
}
