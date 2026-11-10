// Package decode turns the coded values stored in the replication system
// tables into readable names, and back.
//
// Every mapping comes from the Microsoft Learn pages of the corresponding
// system table or stored procedure (read on 2026-11-10), unless a comment says
// otherwise. Unknown values are never dropped: they are rendered in a form
// that Encode* functions accept, so an export always round-trips.
package decode

import (
	"encoding/binary"
	"fmt"
	"strconv"
	"strings"
)

// schemaOption is one documented bit of sysarticles.schema_option.
type schemaOption struct {
	bit  uint64
	name string
}

// schemaOptions lists the bits documented on the sp_addarticle and
// sp_changearticle pages, in bit order.
var schemaOptions = []schemaOption{
	{0x1, "object_creation"},
	{0x2, "custom_procedures"},
	{0x4, "identity_property"},
	{0x8, "timestamp_as_timestamp"},
	{0x10, "clustered_index"},
	{0x20, "udt_to_base_types"},
	{0x40, "nonclustered_indexes"},
	{0x80, "primary_key"},
	{0x100, "user_triggers"},
	{0x200, "foreign_keys"},
	{0x400, "check_constraints"},
	{0x800, "defaults"},
	{0x1000, "column_collation"},
	{0x2000, "extended_properties"},
	{0x4000, "unique_keys"},
	{0x8000, "keys_as_alter_table"},
	{0x10000, "check_constraints_not_for_replication"},
	{0x20000, "foreign_keys_not_for_replication"},
	{0x40000, "partition_filegroups"},
	{0x80000, "table_partition_scheme"},
	{0x100000, "index_partition_scheme"},
	{0x200000, "statistics"},
	{0x400000, "default_bindings"},
	{0x800000, "rule_bindings"},
	{0x1000000, "fulltext_index"},
	{0x2000000, "no_xml_schema_collections"},
	{0x4000000, "xml_indexes"},
	{0x8000000, "create_schemas"},
	{0x10000000, "xml_to_ntext"},
	{0x20000000, "max_types_to_legacy"},
	{0x40000000, "permissions"},
	{0x80000000, "drop_unpublished_dependencies"},
	{0x100000000, "filestream_attribute"},
	{0x200000000, "date_time_to_legacy"},
	{0x400000000, "compression"},
	{0x800000000, "filestream_filegroup"},
	{0x1000000000, "large_clr_udt_to_varbinary"},
	{0x2000000000, "hierarchyid_to_varbinary"},
	{0x4000000000, "filtered_indexes"},
	{0x8000000000, "spatial_to_varbinary"},
	{0x10000000000, "spatial_indexes"},
	{0x20000000000, "sparse_attribute"},
	{0x40000000000, "memory_optimized_table"},
	{0x80000000000, "memory_optimized_clustered_to_nonclustered"},
	{0x400000000000, "nonclustered_columnstore_indexes"},
	{0x800000000000, "filtered_nonclustered_columnstore_indexes"},
}

// SchemaOptionBytes converts the binary(8) value of schema_option to an
// integer. SQL Server stores binary values in big-endian order.
func SchemaOptionBytes(b []byte) (uint64, error) {
	if len(b) > 8 {
		return 0, fmt.Errorf("schema_option: %d bytes, expected at most 8", len(b))
	}
	var buf [8]byte
	copy(buf[8-len(b):], b)
	return binary.BigEndian.Uint64(buf[:]), nil
}

// SchemaOptionNames lists the option names set in v, in bit order. Bits with
// no documented name are rendered as hexadecimal literals ("0x1000000000000").
func SchemaOptionNames(v uint64) []string {
	names := []string{}
	for _, o := range schemaOptions {
		if v&o.bit != 0 {
			names = append(names, o.name)
			v &^= o.bit
		}
	}
	for bit := uint64(1); v != 0; bit <<= 1 {
		if v&bit != 0 {
			names = append(names, fmt.Sprintf("0x%X", bit))
			v &^= bit
		}
	}
	return names
}

// EncodeSchemaOptions is the inverse of SchemaOptionNames.
func EncodeSchemaOptions(names []string) (uint64, error) {
	var v uint64
	for _, n := range names {
		bit, ok := schemaOptionBit(n)
		if !ok {
			return 0, fmt.Errorf("unknown schema option %q", n)
		}
		v |= bit
	}
	return v, nil
}

func schemaOptionBit(name string) (uint64, bool) {
	for _, o := range schemaOptions {
		if o.name == name {
			return o.bit, true
		}
	}
	if strings.HasPrefix(name, "0x") || strings.HasPrefix(name, "0X") {
		bit, err := strconv.ParseUint(name[2:], 16, 64)
		if err == nil && bit != 0 && bit&(bit-1) == 0 {
			return bit, true
		}
	}
	return 0, false
}

// codeTable maps integer codes to names. Unknown codes render as
// "unknown(<code>)".
type codeTable map[int]string

func (t codeTable) name(code int) string {
	if n, ok := t[code]; ok {
		return n
	}
	return fmt.Sprintf("unknown(%d)", code)
}

func (t codeTable) code(name string) (int, error) {
	for c, n := range t {
		if n == name {
			return c, nil
		}
	}
	var c int
	if _, err := fmt.Sscanf(name, "unknown(%d)", &c); err == nil {
		return c, nil
	}
	return 0, fmt.Errorf("unknown value %q", name)
}

// articleTypes maps sysarticles.type and sysschemaarticles.type. Code 96
// (aggregate, schema only) is documented on the sysschemaarticles page only.
var articleTypes = codeTable{
	1:   "logbased",
	3:   "logbased_manualfilter",
	5:   "logbased_manualview",
	7:   "logbased_manualboth",
	8:   "proc_exec",
	24:  "serializable_proc_exec",
	32:  "proc_schema_only",
	64:  "view_schema_only",
	96:  "aggregate_schema_only",
	128: "func_schema_only",
}

// ArticleType returns the name of an article type code.
func ArticleType(code int) string { return articleTypes.name(code) }

// ArticleTypeCode is the inverse of ArticleType.
func ArticleTypeCode(name string) (int, error) { return articleTypes.code(name) }

// preCreationCmds maps sysarticles.pre_creation_cmd. The sysschemaarticles
// page documents 1 and 2 the other way round; that table is decoded with the
// same mapping until it is measured (docs/analysis/step-1-analysis.md, §9).
var preCreationCmds = codeTable{0: "none", 1: "drop", 2: "delete", 3: "truncate"}

// PreCreationCmd returns the name of a pre_creation_cmd code.
func PreCreationCmd(code int) string { return preCreationCmds.name(code) }

// PreCreationCmdCode is the inverse of PreCreationCmd.
func PreCreationCmdCode(name string) (int, error) { return preCreationCmds.code(name) }

// syncMethods maps syspublications.sync_method. Code 2 is not documented.
var syncMethods = codeTable{0: "native", 1: "character", 3: "concurrent", 4: "concurrent_c"}

// SyncMethod returns the name of a sync_method code.
func SyncMethod(code int) string { return syncMethods.name(code) }

// SyncMethodCode is the inverse of SyncMethod.
func SyncMethodCode(name string) (int, error) { return syncMethods.code(name) }

// replFreqs maps syspublications.repl_freq.
var replFreqs = codeTable{0: "transactional", 1: "snapshot"}

// PublicationType returns the name of a repl_freq code.
func PublicationType(code int) string { return replFreqs.name(code) }

// publicationStatuses maps syspublications.status.
var publicationStatuses = codeTable{0: "inactive", 1: "active"}

// PublicationStatus returns the name of a publication status code.
func PublicationStatus(code int) string { return publicationStatuses.name(code) }

// PublicationStatusCode is the inverse of PublicationStatus.
func PublicationStatusCode(name string) (int, error) { return publicationStatuses.code(name) }

// Article status bits (sysarticles.status).
const (
	ArticleStatusActive            = 0x1
	ArticleStatusInsertColumnNames = 0x8
	ArticleStatusParameterized     = 0x10
	// ArticleStatusTimestamp is not on Learn. Measured on SQL Server 2022
	// CU27 (lab/README.md): sp_addarticle sets it, together with
	// ArticleStatusInsertColumnNames, when schema_option has 0x8 (timestamp
	// columns replicated as timestamp). It derives from schema_option and
	// is not configuration of its own.
	ArticleStatusTimestamp = 0x20
	articleStatusKnown     = ArticleStatusActive | ArticleStatusInsertColumnNames | ArticleStatusParameterized | ArticleStatusTimestamp
)

// ArticleStatusUnknownBits returns the bits of an article status that this
// package does not decode.
func ArticleStatusUnknownBits(status int) int { return status &^ articleStatusKnown }

// Publication option bits (syspublications.options).
const (
	PubOptionP2P                  = 0x1
	PubOptionP2PLocalChangesOnly  = 0x2
	PubOptionNonSQLSubscribers    = 0x4
	PubOptionP2PConflictDetection = 0x8
	// PubOptionAllowDrop is not on Learn; it is @OPT_ALLOW_DROP in
	// stored-procedures/sp_MScheck_dropobject.sql:25-29.
	PubOptionAllowDrop      = 0x80
	PubOptionLastWriterWins = 0x100
	pubOptionKnown          = PubOptionP2P | PubOptionP2PLocalChangesOnly | PubOptionNonSQLSubscribers | PubOptionP2PConflictDetection | PubOptionAllowDrop | PubOptionLastWriterWins
)

// PublicationOptionUnknownBits returns the bits of syspublications.options
// that this package does not decode.
func PublicationOptionUnknownBits(options int) int { return options &^ pubOptionKnown }

// Command is a decoded ins_cmd, upd_cmd or del_cmd value.
type Command struct {
	Mode string // CALL, SCALL, MCALL, XCALL, SQL, NONE, or the raw text
	// Schema and Procedure name the procedure of the CALL family, without
	// quotes. Schema is empty when the stored value is not qualified.
	Schema    string
	Procedure string
}

var callModes = map[string]bool{"CALL": true, "SCALL": true, "MCALL": true, "XCALL": true}

// ParseCommand splits a stored command such as "CALL [dbo].[sp_MSins_dboOrders]"
// into its mode and procedure name. An empty value means the command is built
// from the log, which sp_addarticle documents as "SQL". A value it cannot
// split is kept whole in Mode.
func ParseCommand(s string) Command {
	s = strings.TrimSpace(s)
	if s == "" {
		return Command{Mode: "SQL"}
	}
	mode, rest, _ := strings.Cut(s, " ")
	upper := strings.ToUpper(mode)
	switch {
	case callModes[upper]:
		parts, ok := splitName(strings.TrimSpace(rest))
		switch {
		case ok && len(parts) == 1:
			return Command{Mode: upper, Procedure: parts[0]}
		case ok && len(parts) == 2:
			return Command{Mode: upper, Schema: parts[0], Procedure: parts[1]}
		}
	case (upper == "SQL" || upper == "NONE") && strings.TrimSpace(rest) == "":
		return Command{Mode: upper}
	}
	return Command{Mode: s}
}

// String renders the command in the form sp_addarticle expects.
func (c Command) String() string {
	if c.Procedure == "" {
		return c.Mode
	}
	if c.Schema == "" {
		return c.Mode + " " + quoteName(c.Procedure)
	}
	return c.Mode + " " + quoteName(c.Schema) + "." + quoteName(c.Procedure)
}

func quoteName(s string) string { return "[" + strings.ReplaceAll(s, "]", "]]") + "]" }

// splitName splits a T-SQL multipart name ([a].[b], a.b, "a".b) into its
// unquoted parts.
func splitName(s string) ([]string, bool) {
	var parts []string
	for {
		var part string
		switch {
		case strings.HasPrefix(s, "["):
			i := 1
			var b strings.Builder
			for {
				j := strings.IndexByte(s[i:], ']')
				if j < 0 {
					return nil, false
				}
				b.WriteString(s[i : i+j])
				i += j + 1
				if i < len(s) && s[i] == ']' {
					b.WriteByte(']')
					i++
					continue
				}
				break
			}
			part, s = b.String(), s[i:]
		case strings.HasPrefix(s, `"`):
			j := strings.IndexByte(s[1:], '"')
			if j < 0 {
				return nil, false
			}
			part, s = s[1:1+j], s[2+j:]
		default:
			j := strings.IndexByte(s, '.')
			if j < 0 {
				j = len(s)
			}
			part, s = s[:j], s[j:]
			if part == "" || strings.ContainsAny(part, " []\"") {
				return nil, false
			}
		}
		parts = append(parts, part)
		if s == "" {
			return parts, true
		}
		if s[0] != '.' {
			return nil, false
		}
		s = s[1:]
	}
}

// Initialization decodes syssubscriptions.sync_type and nosync_type.
func Initialization(syncType, nosyncType int) string {
	if syncType == 1 {
		return "snapshot"
	}
	if syncType == 2 {
		switch nosyncType {
		case 0:
			return "none"
		case 1:
			return "replication_support_only"
		case 2:
			return "backup"
		case 3:
			return "lsn"
		}
	}
	return fmt.Sprintf("unknown(sync_type=%d,nosync_type=%d)", syncType, nosyncType)
}

// SecurityMode decodes the *_security_mode columns: 0 = SQL Server
// authentication, 1 = Windows authentication.
func SecurityMode(code int) string {
	switch code {
	case 0:
		return "sql"
	case 1:
		return "windows"
	}
	return fmt.Sprintf("unknown(%d)", code)
}

// msdb.dbo.sysschedules codes.
var freqTypes = codeTable{
	1: "once", 4: "daily", 8: "weekly", 16: "monthly", 32: "monthly_relative",
	64: "agent_start", 128: "idle",
}
var freqSubdayTypes = codeTable{1: "at_time", 2: "seconds", 4: "minutes", 8: "hours"}

// FreqType decodes sysschedules.freq_type.
func FreqType(code int) string { return freqTypes.name(code) }

// FreqSubdayType decodes sysschedules.freq_subday_type.
func FreqSubdayType(code int) string { return freqSubdayTypes.name(code) }

// agentTypes maps msdb.dbo.MSagent_profiles.agent_type.
var agentTypes = codeTable{1: "snapshot", 2: "logreader", 3: "distribution", 4: "merge", 9: "queuereader"}

// AgentType decodes MSagent_profiles.agent_type.
func AgentType(code int) string { return agentTypes.name(code) }
