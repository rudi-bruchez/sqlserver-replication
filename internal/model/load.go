package model

import (
	"bytes"
	"fmt"
	"io"

	"gopkg.in/yaml.v3"
)

// Load reads a configuration file. It refuses unknown keys and any format
// version other than FormatVersion. An omitted property loads as nil.
func Load(r io.Reader) (*Config, error) {
	data, err := io.ReadAll(r)
	if err != nil {
		return nil, err
	}
	// The version is checked before the strict decoding, so that a file of
	// another version is refused for its version rather than for the first
	// key that changed.
	var head struct {
		Version int `yaml:"version"`
	}
	if err := yaml.Unmarshal(data, &head); err != nil {
		return nil, err
	}
	if head.Version != FormatVersion {
		return nil, fmt.Errorf("format version %d, this sqlrepl reads %d", head.Version, FormatVersion)
	}
	dec := yaml.NewDecoder(bytes.NewReader(data))
	dec.KnownFields(true)
	var c Config
	if err := dec.Decode(&c); err != nil {
		return nil, err
	}
	return &c, nil
}

// Marshal writes a configuration file.
func Marshal(c *Config) ([]byte, error) {
	return yaml.Marshal(c)
}
