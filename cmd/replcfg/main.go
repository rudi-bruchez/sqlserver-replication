// Command replcfg manages the configuration of SQL Server transactional
// replication as a declarative file.
//
// Only the export is implemented: it reads a publication database, its
// publications, articles, push subscriptions and agents, and writes them as
// YAML. It runs SELECT statements only.
package main

import (
	"context"
	"database/sql"
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
	"gopkg.in/yaml.v3"

	"github.com/rudi-bruchez/sqlserver-replication/internal/reader"
)

const usage = `replcfg manages SQL Server transactional replication as a declarative file.

Usage:
  replcfg export -publisher SERVER -database DB [options]

Run "replcfg export -h" for the export options.
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
		fmt.Fprintln(os.Stderr, "replcfg:", err)
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
	user := fs.String("user", "", "SQL Server login; the password is read from REPLCFG_PASSWORD (default: Windows authentication)")
	output := fs.String("o", "", "output file (default: standard output)")
	timeout := fs.Duration("timeout", 2*time.Minute, "overall timeout")
	params := paramFlags{}
	fs.Var(params, "param", "extra connection parameter key=value, repeatable (e.g. -param encrypt=disable)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *publisher == "" || *database == "" {
		fs.Usage()
		return fmt.Errorf("-publisher and -database are required")
	}

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()

	cp := connParams{User: *user, Password: os.Getenv("REPLCFG_PASSWORD"), Extra: params}
	pub, err := open(ctx, *publisher, *database, cp)
	if err != nil {
		return fmt.Errorf("publisher: %w", err)
	}
	defer pub.Close()

	if *distributor == "" {
		name, err := reader.DistributorName(ctx, pub)
		if err != nil {
			return err
		}
		*distributor = name
	}
	dist, err := open(ctx, *distributor, "", cp)
	if err != nil {
		return fmt.Errorf("distributor: %w", err)
	}
	defer dist.Close()

	cfg, err := reader.Export(ctx, reader.Source{
		Publisher:     pub,
		Distributor:   dist,
		Database:      *database,
		PublisherName: *publisherName,
	})
	if err != nil {
		return err
	}

	out, err := yaml.Marshal(cfg)
	if err != nil {
		return err
	}
	for _, w := range cfg.Warnings {
		fmt.Fprintln(os.Stderr, "warning:", w)
	}
	if *output == "" {
		_, err = stdout.Write(out)
		return err
	}
	return os.WriteFile(*output, out, 0o644)
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
