package model

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"reflect"
	"strings"

	"gopkg.in/yaml.v3"
)

// Load reads a configuration file. It refuses unknown keys, any format
// version other than FormatVersion, a null list element and a second YAML
// document. An omitted property loads as nil.
func Load(r io.Reader) (*Config, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return nil, err
	}
	dec := yaml.NewDecoder(bytes.NewReader(data))
	var doc yaml.Node
	if err := dec.Decode(&doc); err != nil && !errors.Is(err, io.EOF) {
		return nil, err
	}
	var next yaml.Node
	if err := dec.Decode(&next); !errors.Is(err, io.EOF) {
		if err != nil {
			return nil, err
		}
		return nil, errors.New("more than one YAML document")
	}
	// yaml.v3 drops a null element of a list, and [~] would load as a
	// declared empty list.
	if err := nullListElement(&doc); err != nil {
		return nil, err
	}

	// The version is checked before the strict decoding, so that a file of
	// another version is refused for its version rather than for the first
	// key that changed.
	var head struct {
		Version int `yaml:"version"`
	}
	if err := doc.Decode(&head); err != nil {
		return nil, err
	}
	if head.Version != FormatVersion {
		return nil, fmt.Errorf("format version %d, this sqlrepl reads %d", head.Version, FormatVersion)
	}
	// yaml.Node.Decode has no KnownFields: the strict decoding reads the
	// bytes again, which hold this one document only.
	strict := yaml.NewDecoder(bytes.NewReader(data))
	strict.KnownFields(true)
	var c Config
	if err := strict.Decode(&c); err != nil {
		return nil, err
	}
	if err := duplicateKeys(reflect.ValueOf(&c).Elem(), ""); err != nil {
		return nil, err
	}
	return &c, nil
}

// duplicateKeys refuses two elements of a list with the same key, under
// any list of the model: publications, articles, subscriptions, shared agents,
// agent profiles. Schedules are left out: see below. The key of a subscription or a shared agent
// names a server and a database, which the reader compares in any case:
// there it is compared case-insensitively. The enumerations are not checked
// here: plan 3's normalization does it.
func duplicateKeys(sv reflect.Value, path string) error {
	t := sv.Type()
	for i := range t.NumField() {
		f := t.Field(i)
		tag, ok := f.Tag.Lookup("yaml")
		if !f.IsExported() || !ok || f.Type == findingsType {
			continue
		}
		key, opts, _ := strings.Cut(tag, ",")
		fv := sv.Field(i)
		if hasOption(opts, "inline") {
			if err := duplicateKeys(fv, path); err != nil {
				return err
			}
			continue
		}
		if key == "" {
			key = strings.ToLower(f.Name)
		}
		p := Join(path, key)
		if fv.Kind() == reflect.Pointer {
			if fv.IsNil() {
				continue
			}
			fv = fv.Elem()
		}
		switch fv.Kind() {
		case reflect.Struct:
			if err := duplicateKeys(fv, p); err != nil {
				return err
			}
		case reflect.Slice:
			if fv.Type().Elem().Kind() != reflect.Struct {
				continue
			}
			seen := map[string]string{}
			for j := range fv.Len() {
				e := fv.Index(j)
				k := e.Addr().Interface().(interface{ Key() string }).Key()
				cmp := k
				check := true
				switch e.Interface().(type) {
				case Subscription, SharedDistributionAgent, SharedPullAgent:
					cmp = strings.ToUpper(k)
				case Schedule:
					// msdb allows two schedules of one job with the same name
					// (measured with sp_add_jobschedule) and the export writes
					// both; schedules are compared as a list (Agent.Schedules),
					// so their names need not be unique.
					check = false
				}
				if first, dup := seen[cmp]; check && dup {
					return fmt.Errorf("%s: duplicate key %q (first %q)", p, k, first)
				}
				seen[cmp] = k
				if err := duplicateKeys(e, p+Element(k)); err != nil {
					return err
				}
			}
		}
	}
	return nil
}

func nullListElement(n *yaml.Node) error {
	for _, child := range n.Content {
		if n.Kind == yaml.SequenceNode && child.Kind == yaml.ScalarNode && child.Tag == "!!null" {
			return fmt.Errorf("line %d: null list element", child.Line)
		}
		if err := nullListElement(child); err != nil {
			return err
		}
	}
	return nil
}

// Marshal writes a configuration file.
func Marshal(c *Config) ([]byte, error) {
	return yaml.Marshal(c)
}
