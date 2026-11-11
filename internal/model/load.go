package model

import (
	"bytes"
	"errors"
	"fmt"
	"io"

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
	return &c, nil
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
