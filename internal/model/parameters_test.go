package model

import (
	"bufio"
	"fmt"
	"os"
	"reflect"
	"strconv"
	"strings"
	"testing"
)

// parameterVersions are the versions whose lab/results/<v>/17-parameters.txt
// the coverage test reads, oldest first.
var parameterVersions = []string{"2019", "2022", "2025"}

// readParameterListing returns the procedure.@parameter names of a
// 17-parameters.txt file, and false when the file does not exist.
func readParameterListing(t *testing.T, version string) ([]string, bool) {
	t.Helper()
	f, err := os.Open("../../lab/results/" + version + "/17-parameters.txt")
	if os.IsNotExist(err) {
		return nil, false
	}
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	var names []string
	total := -1
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fields := strings.Split(sc.Text(), "|")
		if len(fields) < 3 || fields[0] != "R" {
			continue
		}
		if fields[1] == "TOTAL" {
			if total, err = strconv.Atoi(fields[2]); err != nil {
				t.Fatalf("%s: TOTAL %q", version, fields[2])
			}
			continue
		}
		names = append(names, fields[1])
	}
	if err := sc.Err(); err != nil {
		t.Fatal(err)
	}
	if total != len(names) {
		t.Fatalf("%s: %d rows, TOTAL says %d", version, len(names), total)
	}
	return names, true
}

func TestParametersCovered(t *testing.T) {
	entries := map[string]int{}
	for _, m := range Parameters {
		entries[m.Procedure+"."+m.Parameter]++
	}
	since := map[string]string{} // first version listing the parameter
	read := 0
	for _, v := range parameterVersions {
		names, ok := readParameterListing(t, v)
		if !ok {
			if v == "2022" {
				t.Fatal("lab/results/2022/17-parameters.txt is missing")
			}
			continue
		}
		read++
		for _, n := range names {
			if _, ok := since[n]; !ok {
				since[n] = v
			}
			if c := entries[n]; c != 1 {
				t.Errorf("%s (listed in %s): %d entries in Parameters, want 1", n, v, c)
			}
		}
	}
	if read == 0 {
		t.Fatal("no parameter listing read")
	}
	for _, m := range Parameters {
		n := m.Procedure + "." + m.Parameter
		first, listed := since[n]
		if !listed {
			t.Errorf("%s: not listed in any 17-parameters.txt", n)
		}
		switch m.Kind {
		case ParamField, ParamCreationOnly, ParamExcluded:
		default:
			t.Errorf("%s: kind %q", n, m.Kind)
		}
		if m.Kind != ParamField && m.Reason == "" {
			t.Errorf("%s: %s without a reason", n, m.Kind)
		}
		if m.Kind == ParamExcluded && len(m.Paths) != 0 {
			t.Errorf("%s: excluded with paths %q", n, m.Paths)
		}
		if m.Kind != ParamExcluded && len(m.Paths) == 0 {
			t.Errorf("%s: %s without a path", n, m.Kind)
		}
		if listed && m.Since != first {
			t.Errorf("%s: since %q, want %q (the oldest listing that has it)", n, m.Since, first)
		}
	}
	if len(entries) != len(Parameters) {
		t.Errorf("%d entries for %d distinct parameters", len(Parameters), len(entries))
	}
}

func TestParameterPathsResolve(t *testing.T) {
	root := reflect.TypeFor[Config]()
	for _, m := range Parameters {
		for _, p := range m.Paths {
			if err := resolvePattern(root, p); err != nil {
				t.Errorf("%s.%s: %s: %v", m.Procedure, m.Parameter, p, err)
			}
		}
	}
}

// resolvePattern follows a path pattern through the model types by YAML key:
// "[*]" enters a slice element, inline structs are flattened, and a map
// accepts any one key after it.
func resolvePattern(t reflect.Type, pattern string) error {
	segs := strings.Split(pattern, ".")
	for i, seg := range segs {
		for t.Kind() == reflect.Pointer {
			t = t.Elem()
		}
		if t.Kind() == reflect.Map {
			if strings.Contains(seg, "[") || i != len(segs)-1 {
				return fmt.Errorf("%q after a map must be its last segment, a plain key", seg)
			}
			return nil
		}
		if t.Kind() != reflect.Struct {
			return fmt.Errorf("%q under %s, which has no keys", seg, t)
		}
		key, elem := strings.CutSuffix(seg, "[*]")
		f, ok := fieldByYAMLKey(t, key)
		if !ok {
			return fmt.Errorf("%s has no key %q", t, key)
		}
		t = f
		if elem {
			for t.Kind() == reflect.Pointer {
				t = t.Elem()
			}
			if t.Kind() != reflect.Slice {
				return fmt.Errorf("%q is %s, not a list", key, t)
			}
			t = t.Elem()
		} else if i != len(segs)-1 {
			u := t
			for u.Kind() == reflect.Pointer {
				u = u.Elem()
			}
			if u.Kind() == reflect.Slice {
				return fmt.Errorf("%q is a list: write %s[*]", key, key)
			}
		}
	}
	return nil
}

// fieldByYAMLKey returns the type of the field of struct t whose YAML key is
// key, looking into inline fields.
func fieldByYAMLKey(t reflect.Type, key string) (reflect.Type, bool) {
	for i := range t.NumField() {
		f := t.Field(i)
		tag, ok := f.Tag.Lookup("yaml")
		if !f.IsExported() || !ok {
			continue
		}
		k, opts, _ := strings.Cut(tag, ",")
		if hasOption(opts, "inline") {
			if ft, ok := fieldByYAMLKey(f.Type, key); ok {
				return ft, true
			}
			continue
		}
		if k == "" {
			k = strings.ToLower(f.Name)
		}
		if k == key {
			return f.Type, true
		}
	}
	return nil, false
}
