package cost

// The result fields that recur in the flag rows (02-matrix, 05-snapshot-flag,
// 09-snapshot-pub, 18-reverse), copied from the rows.
const (
	allOK    = "f00=ok,f10=ok,f01=ok,f11=ok"
	invOK    = "f00=20607,f10=ok,f01=20607,f11=ok"
	bothOK   = "f00=20607,f10=20608,f01=20607,f11=ok"
	reinitOK = "f00=20608,f10=20608,f01=ok,f11=ok"
	add2Inv  = "f00=20607,f10=ok"
	add2OK   = "f00=ok,f10=ok"
)

// The states the rows measured: ready or not, operated rows at status 2 or
// not. 02-matrix SalesPub is rdy2 and SalesRef non2; 18-reverse RV.I is rdy2,
// RV.N non2 and RV.P non1 (no row); 09-snapshot-pub SNAP and TWIN are non2,
// SNAPI rdy2.
var (
	rdy2 = FlagState{Ready: true, At2: true}
	rdy1 = FlagState{Ready: true}
	non2 = FlagState{At2: true}
	non1 = FlagState{}
)

func cite(row, expect string, s FlagState) Cite {
	return Cite{Row: row, Expect: expect, Ready: s.Ready, At2: s.At2}
}

// File prefixes of the cited rows.
const (
	mx = "02-matrix "
	sf = "05-snapshot-flag "
	st = "06-structural "
	ch = "07-changes "
	pl = "08-pull "
	sp = "09-snapshot-pub "
	fv = "14-filter-view "
	ss = "15-snapshot-scope "
	rv = "18-reverse "
	pf = "19-profiles "
)

// scopeMethods are the five immediate_sync publications of 15-snapshot-scope
// section C.
var scopeMethods = []string{"native", "character", "concurrent", "concurrent_c", "dbsnap"}

// scopeC cites the C.<method>.<op> row of every method, all ready with their
// rows at 2.
func scopeC(op, expect string) []Cite {
	var cs []Cite
	for _, m := range scopeMethods {
		cs = append(cs, cite(ss+"C."+m+"."+op, expect, rdy2))
	}
	return cs
}

// cat concatenates cite lists.
func cat(lists ...[]Cite) []Cite {
	var cs []Cite
	for _, l := range lists {
		cs = append(cs, l...)
	}
	return cs
}

const (
	tr = "transactional"
	sn = "snapshot"

	pub = "publications[*]."
	art = "publications[*].articles[*]."
	sub = "publications[*].subscriptions[*]."
)

// Table is the measured cost table. Each entry cites the rows it comes
// from; TestCostTableMatchesRows checks it against them.
var Table = []Entry{
	// Publication properties.
	{Change: pub + "description", Dir: "set", PubType: tr, Procedure: "sp_changepublication", Property: "description", Class: Online,
		Cites: []Cite{cite(mx+"P01", allOK, rdy2), cite(mx+"P02", allOK, non2)}},
	{Change: pub + "description", Dir: "set", PubType: sn, Procedure: "sp_changepublication", Property: "description", Class: Online,
		Cites: []Cite{cite(sp+"SNAP.P01", allOK, non2), cite(sp+"SNAPI.P01", allOK, rdy2)}},

	{Change: pub + "retention_hours", PubType: tr, Procedure: "sp_changepublication", Property: "retention", Class: Online,
		Cites: []Cite{cite(mx+"P03", allOK, rdy2), cite(mx+"P04", allOK, non2)}},
	{Change: pub + "retention_hours", PubType: sn, Procedure: "sp_changepublication", Property: "retention", Class: Online,
		Cites: []Cite{cite(sp+"SNAP.P02", allOK, non2), cite(sp+"SNAPI.P02", allOK, rdy2)}},

	{Change: pub + "replicate_ddl", Dir: "to_false", PubType: tr, Procedure: "sp_changepublication", Property: "replicate_ddl", Class: Online,
		Cites: []Cite{cite(mx+"P05", allOK, rdy2), cite(mx+"P06", allOK, non2)}},
	{Change: pub + "replicate_ddl", Dir: "to_true", PubType: tr, Procedure: "sp_changepublication", Property: "replicate_ddl", Class: Online,
		Cites: []Cite{cite(rv+"RV.I.replicate_ddl", allOK, rdy2), cite(rv+"RV.N.replicate_ddl", allOK, non2)}},
	{Change: pub + "replicate_ddl", Dir: "to_false", PubType: sn, Procedure: "sp_changepublication", Property: "replicate_ddl", Class: Online,
		Cites: []Cite{cite(sp+"SNAP.P03", allOK, non2), cite(sp+"SNAPI.P03", allOK, rdy2)}},

	{Change: pub + "allow_pull", Dir: "to_false", PubType: tr, Procedure: "sp_changepublication", Property: "allow_pull", Class: Online,
		Cites: []Cite{cite(mx+"P07", allOK, rdy2), cite(rv+"RV.I.allow_pull", allOK, rdy2), cite(rv+"RV.N.allow_pull", allOK, non2)}},
	{Change: pub + "allow_pull", Dir: "to_true", PubType: tr, Procedure: "sp_changepublication", Property: "allow_pull", Class: Online,
		Cites: []Cite{cite(mx+"P08", allOK, non2)}},
	{Change: pub + "allow_pull", Dir: "to_true", PubType: sn, Procedure: "sp_changepublication", Property: "allow_pull", Class: Online,
		Cites: []Cite{cite(sp+"SNAP.P04", allOK, non2), cite(sp+"SNAPI.P04", allOK, rdy2)}},

	// allow_push false is refused with 20012 while push subscriptions exist
	// (P09, SNAP.P05): they are dropped in step 4 first, and rule 7 refuses a
	// push subscription on such a publication.
	{Change: pub + "allow_push", Dir: "to_false", PubType: tr, Procedure: "sp_changepublication", Property: "allow_push", Class: Online,
		Cites: []Cite{cite(rv+"RV.P.allow_push_false", allOK, non1)},
		Counter: []Cite{
			cite(mx+"P09", "f00=20012,f10=20012,f01=20012,f11=20012", rdy2),
			cite(sp+"SNAP.P05", "f00=20012,f10=20012,f01=20012,f11=20012", non2),
		}},
	{Change: pub + "allow_push", Dir: "to_true", PubType: tr, Procedure: "sp_changepublication", Property: "allow_push", Class: Online,
		Cites: []Cite{cite(rv+"RV.P.allow_push", allOK, non1)}},

	{Change: pub + "allow_initialize_from_backup", Dir: "to_true", PubType: tr, Procedure: "sp_changepublication", Property: "allow_initialize_from_backup", Class: Online,
		Cites: []Cite{cite(mx+"P10", allOK, rdy2), cite(mx+"P11", allOK, non2)}},
	{Change: pub + "allow_initialize_from_backup", Dir: "to_false", PubType: tr, Procedure: "sp_changepublication", Property: "allow_initialize_from_backup", Class: Online,
		Cites: []Cite{cite(rv+"RV.I.allow_initialize_from_backup", allOK, rdy2), cite(rv+"RV.N.allow_initialize_from_backup", allOK, non2)}},
	{Change: pub + "allow_initialize_from_backup", Dir: "to_true", PubType: sn, Procedure: "sp_changepublication", Property: "allow_initialize_from_backup", Class: Refused, Error: 18787,
		Cites: []Cite{
			cite(sp+"SNAP.P06", "f00=18787,f10=18787,f01=18787,f11=18787", non2),
			cite(sp+"SNAPI.P06", "f00=18787,f10=18787,f01=18787,f11=18787", rdy2),
		}},

	// allow_subscription_copy true needs immediate_sync (P13, 21210).
	{Change: pub + "allow_subscription_copy", Dir: "to_true", PubType: tr, Procedure: "sp_changepublication", Property: "allow_subscription_copy", Class: Online,
		Cites:   []Cite{cite(mx+"P12", allOK, rdy2)},
		Counter: []Cite{cite(mx+"P13", "f00=21210,f10=21210,f01=21210,f11=21210", non2)}},
	{Change: pub + "allow_subscription_copy", Dir: "to_false", PubType: tr, Procedure: "sp_changepublication", Property: "allow_subscription_copy", Class: Online,
		Cites: []Cite{cite(rv+"RV.I.allow_subscription_copy", allOK, rdy2)}},
	{Change: pub + "allow_subscription_copy", Dir: "to_true", PubType: sn, Procedure: "sp_changepublication", Property: "allow_subscription_copy", Class: Online,
		Cites:   []Cite{cite(sp+"SNAPI.P07", allOK, rdy2)},
		Counter: []Cite{cite(sp+"SNAP.P07", "f00=21210,f10=21210,f01=21210,f11=21210", non2)}},

	{Change: pub + "allow_partition_switch", Dir: "to_true", PubType: tr, Procedure: "sp_changepublication", Property: "allow_partition_switch", Class: Online,
		Cites: []Cite{cite(mx+"P14", allOK, rdy2), cite(mx+"P15", allOK, non2)}},
	{Change: pub + "allow_partition_switch", Dir: "to_false", PubType: tr, Procedure: "sp_changepublication", Property: "allow_partition_switch", Class: Online,
		Cites: []Cite{cite(rv+"RV.I.allow_partition_switch", allOK, rdy2), cite(rv+"RV.N.allow_partition_switch", allOK, non2)}},
	{Change: pub + "allow_partition_switch", Dir: "to_true", PubType: sn, Procedure: "sp_changepublication", Property: "allow_partition_switch", Class: Online,
		Cites: []Cite{cite(sp+"SNAP.P08", allOK, non2), cite(sp+"SNAPI.P08", allOK, rdy2)}},

	// replicate_partition_switch true needs allow_partition_switch (P16, 21866).
	{Change: pub + "replicate_partition_switch", Dir: "to_true", PubType: tr, Procedure: "sp_changepublication", Property: "replicate_partition_switch", Class: Online,
		Cites:   []Cite{cite(rv+"RV.I.replicate_partition_switch_true", allOK, rdy2), cite(rv+"RV.N.replicate_partition_switch_true", allOK, non2)},
		Counter: []Cite{cite(mx+"P16", "f00=21866,f10=21866,f01=21866,f11=21866", rdy2)}},
	{Change: pub + "replicate_partition_switch", Dir: "to_false", PubType: tr, Procedure: "sp_changepublication", Property: "replicate_partition_switch", Class: Online,
		Cites: []Cite{cite(rv+"RV.I.replicate_partition_switch", allOK, rdy2), cite(rv+"RV.N.replicate_partition_switch", allOK, non2)}},

	{Change: pub + "allow_drop", Dir: "to_true", PubType: tr, Procedure: "sp_changepublication", Property: "allow_drop", Class: Online,
		Cites: []Cite{cite(mx+"P17", allOK, rdy2), cite(mx+"P18", allOK, non2)}},
	{Change: pub + "allow_drop", Dir: "to_false", PubType: tr, Procedure: "sp_changepublication", Property: "allow_drop", Class: Online,
		Cites: []Cite{cite(rv+"RV.I.allow_drop", allOK, rdy2), cite(rv+"RV.N.allow_drop", allOK, non2)}},
	{Change: pub + "allow_drop", Dir: "to_true", PubType: sn, Procedure: "sp_changepublication", Property: "allow_drop", Class: Online,
		Cites: []Cite{cite(sp+"SNAP.P10", allOK, non2), cite(sp+"SNAPI.P10", allOK, rdy2)}},

	// status is an enum: one entry for both values (R8), inactive measured
	// by P19, P20 and SNAP.P11, active by RV.P.status.
	{Change: pub + "status", PubType: tr, Procedure: "sp_changepublication", Property: "status", Class: Online,
		Cites: []Cite{cite(mx+"P19", allOK, rdy2), cite(mx+"P20", allOK, non2), cite(rv+"RV.P.status", allOK, non1)}},
	{Change: pub + "status", PubType: sn, Procedure: "sp_changepublication", Property: "status", Class: Online,
		Cites: []Cite{cite(sp+"SNAP.P11", allOK, non2), cite(sp+"SNAPI.P11", allOK, rdy2)}},

	{Change: pub + "immediate_sync", Dir: "to_false", PubType: tr, Procedure: "sp_changepublication", Property: "immediate_sync", Class: DropsReady,
		Cites: cat([]Cite{cite(mx+"P23", allOK, rdy2)}, scopeC("immediate_sync_false", "f00"),
			[]Cite{cite(ss+"B.native_noanon.1b", "f00", rdy2)})},
	// immediate_sync true needs independent_agent (P24, 21022).
	{Change: pub + "immediate_sync", Dir: "to_true", PubType: tr, Procedure: "sp_changepublication", Property: "immediate_sync", Class: Online,
		Cites:   []Cite{cite(ss+"B.native_anon.4a", "f00", non2)},
		Counter: []Cite{cite(mx+"P24", "f00=21022,f10=21022,f01=21022,f11=21022", non2)}},
	{Change: pub + "immediate_sync", Dir: "to_false", PubType: sn, Procedure: "sp_changepublication", Property: "immediate_sync", Class: DropsReady,
		Cites: []Cite{cite(sp+"SNAPI.P15", allOK, rdy2)}},

	// independent_agent cannot change while subscriptions exist (20013);
	// false under immediate_sync is 21022 (P25), the chain Task 13 orders.
	{Change: pub + "independent_agent", Dir: "both", PubType: tr, Procedure: "sp_changepublication", Property: "independent_agent", Class: DropReadd, Error: 20013,
		Cites:   []Cite{cite(mx+"P26", "f00=20013,f10=20013,f01=20013,f11=20013", non2)},
		Counter: []Cite{cite(mx+"P25", "f00=21022,f10=21022,f01=21022,f11=21022", rdy2)}},
	{Change: pub + "independent_agent", Dir: "both", PubType: sn, Procedure: "sp_changepublication", Property: "independent_agent", Class: DropReadd, Error: 20013,
		Cites:   []Cite{cite(sp+"SNAP.P16", "f00=20013,f10=20013,f01=20013,f11=20013", non2)},
		Counter: []Cite{cite(sp+"SNAPI.P16", "f00=21022,f10=21022,f01=21022,f11=21022", rdy2)}},

	// enabled_for_het_sub cannot change while subscriptions exist (20640).
	{Change: pub + "enabled_for_het_sub", Dir: "both", PubType: tr, Procedure: "sp_changepublication", Property: "enabled_for_het_sub", Class: DropReadd, Error: 20640,
		Cites: []Cite{cite(mx+"P37", "f00=20640,f10=20640,f01=20640,f11=20640", rdy2)}},
	{Change: pub + "enabled_for_het_sub", Dir: "both", PubType: sn, Procedure: "sp_changepublication", Property: "enabled_for_het_sub", Class: DropReadd, Error: 20640,
		Cites: []Cite{
			cite(sp+"SNAP.P24", "f00=20640,f10=20640,f01=20640,f11=20640", non2),
			cite(sp+"SNAPI.P24", "f00=20640,f10=20640,f01=20640,f11=20640", rdy2),
		}},

	// allow_anonymous true needs immediate_sync (P28, SNAP.P17, 20011).
	{Change: pub + "allow_anonymous", Dir: "to_true", PubType: tr, Procedure: "sp_changepublication", Property: "allow_anonymous", Class: Online,
		Cites:   []Cite{cite(mx+"P27", allOK, rdy2)},
		Counter: []Cite{cite(mx+"P28", "f00=20011,f10=20011,f01=20011,f11=20011", non2)}},
	{Change: pub + "allow_anonymous", Dir: "to_true", PubType: sn, Procedure: "sp_changepublication", Property: "allow_anonymous", Class: Online,
		Cites:   []Cite{cite(sp+"SNAPI.P17", allOK, rdy2)},
		Counter: []Cite{cite(sp+"SNAP.P17", "f00=20011,f10=20011,f01=20011,f11=20011", non2)}},
	{Change: pub + "allow_anonymous", Dir: "to_false", PubType: tr, Procedure: "sp_changepublication", Property: "allow_anonymous", Class: DropsReady,
		Cites: []Cite{cite(ss+"B.native_anon.1a", "f00", rdy2), cite(ss+"B.concurrent_anon.1a", "f00", rdy2)}},

	// Snapshot location and scripts.
	{Change: pub + "snapshot.alt_folder", Dir: "set", PubType: tr, Procedure: "sp_changepublication", Property: "alt_snapshot_folder", Class: Snapshot,
		Cites: cat([]Cite{cite(mx+"P29", invOK, rdy2), cite(mx+"P30", allOK, non2)}, scopeC("alt_snapshot_folder", "f10"))},
	{Change: pub + "snapshot.alt_folder", Dir: "clear", PubType: tr, Procedure: "sp_changepublication", Property: "alt_snapshot_folder", Class: Snapshot,
		Cites: []Cite{
			cite(rv+"RV.I.alt_snapshot_folder.empty", invOK, rdy2), cite(rv+"RV.I.alt_snapshot_folder.null", invOK, rdy2),
			cite(rv+"RV.N.alt_snapshot_folder.empty", allOK, non2), cite(rv+"RV.N.alt_snapshot_folder.null", allOK, non2),
		}},
	{Change: pub + "snapshot.alt_folder", Dir: "set", PubType: sn, Procedure: "sp_changepublication", Property: "alt_snapshot_folder", Class: Snapshot,
		Cites: []Cite{cite(sp+"SNAP.P18", allOK, non2), cite(sp+"SNAPI.P18", invOK, rdy2)}},

	{Change: pub + "snapshot.in_default_folder", Dir: "to_false", PubType: tr, Procedure: "sp_changepublication", Property: "snapshot_in_defaultfolder", Class: Snapshot,
		Cites: []Cite{cite(mx+"P31", invOK, rdy2)}},
	{Change: pub + "snapshot.in_default_folder", Dir: "to_false", PubType: sn, Procedure: "sp_changepublication", Property: "snapshot_in_defaultfolder", Class: Snapshot,
		Cites: []Cite{cite(sp+"SNAP.P19", allOK, non2), cite(sp+"SNAPI.P19", invOK, rdy2)}},
	{Change: pub + "snapshot.in_default_folder", Dir: "to_true", PubType: tr, Procedure: "sp_changepublication", Property: "snapshot_in_defaultfolder", Class: Snapshot,
		Cites: []Cite{cite(rv+"RV.I.snapshot_in_defaultfolder", invOK, rdy2), cite(rv+"RV.N.snapshot_in_defaultfolder", allOK, non2)}},

	{Change: pub + "snapshot.pre_script", Dir: "set", PubType: tr, Procedure: "sp_changepublication", Property: "pre_snapshot_script", Class: Snapshot,
		Cites: []Cite{cite(mx+"P33", invOK, rdy2), cite(mx+"P34", allOK, non2)}},
	{Change: pub + "snapshot.pre_script", Dir: "clear", PubType: tr, Procedure: "sp_changepublication", Property: "pre_snapshot_script", Class: Snapshot,
		Cites: []Cite{
			cite(rv+"RV.I.pre_snapshot_script.empty", invOK, rdy2), cite(rv+"RV.I.pre_snapshot_script.null", invOK, rdy2),
			cite(rv+"RV.N.pre_snapshot_script.empty", allOK, non2), cite(rv+"RV.N.pre_snapshot_script.null", allOK, non2),
		}},
	{Change: pub + "snapshot.pre_script", Dir: "set", PubType: sn, Procedure: "sp_changepublication", Property: "pre_snapshot_script", Class: Snapshot,
		Cites: []Cite{cite(sp+"SNAP.P21", allOK, non2), cite(sp+"SNAPI.P21", invOK, rdy2)}},
	{Change: pub + "snapshot.post_script", Dir: "set", PubType: tr, Procedure: "sp_changepublication", Property: "post_snapshot_script", Class: Snapshot,
		Cites: []Cite{cite(mx+"P35", invOK, rdy2)}},
	{Change: pub + "snapshot.post_script", Dir: "clear", PubType: tr, Procedure: "sp_changepublication", Property: "post_snapshot_script", Class: Snapshot,
		Cites: []Cite{
			cite(rv+"RV.I.post_snapshot_script.empty", invOK, rdy2), cite(rv+"RV.I.post_snapshot_script.null", invOK, rdy2),
			cite(rv+"RV.N.post_snapshot_script.empty", allOK, non2), cite(rv+"RV.N.post_snapshot_script.null", allOK, non2),
		}},
	{Change: pub + "snapshot.post_script", Dir: "set", PubType: sn, Procedure: "sp_changepublication", Property: "post_snapshot_script", Class: Snapshot,
		Cites: []Cite{cite(sp+"SNAP.P22", allOK, non2), cite(sp+"SNAPI.P22", invOK, rdy2)}},

	{Change: pub + "snapshot.ftp.address", Dir: "set", PubType: tr, Procedure: "sp_changepublication", Property: "ftp_address", Class: Snapshot,
		Cites: []Cite{cite(mx+"P38", invOK, rdy2)}},
	{Change: pub + "snapshot.ftp.address", Dir: "set", PubType: sn, Procedure: "sp_changepublication", Property: "ftp_address", Class: Snapshot,
		Cites: []Cite{cite(sp+"SNAP.P25", allOK, non2), cite(sp+"SNAPI.P25", invOK, rdy2)}},

	// sync_method pairs (R19). A change from or to concurrent or concurrent_c
	// marks every subscription row; within native, character and database
	// snapshot it marks nothing.
	{Change: pub + "sync_method", Dir: "native>concurrent", PubType: tr, Procedure: "sp_changepublication", Property: "sync_method", Class: SnapshotReinit, Wide: true,
		Cites: []Cite{
			cite(ss+"C.native.sync_method", "f11", rdy2),
			cite(ss+"D.non_native_pub.change", "f01", non2),
			cite(mx+"P22", reinitOK, non2),
		}},
	{Change: pub + "sync_method", Dir: "concurrent>native", PubType: tr, Procedure: "sp_changepublication", Property: "sync_method", Class: SnapshotReinit, Wide: true,
		Cites: []Cite{
			cite(ss+"C.concurrent.sync_method", "f11", rdy2), cite(mx+"P21", "f00=20607,f10=20608,f01=20607,f11=ok", rdy2),
			// 05-snapshot-flag O6 on the concurrent publication: the reinit
			// flag is asked when any row is at 2 (S5, S6: rows at 1 and 2).
			cite(sf+"S2.O6", allOK, non1), cite(sf+"S3.O6", reinitOK, non2), cite(sf+"S5.O6", reinitOK, non2),
			cite(sf+"S6.O6", reinitOK, non2), cite(sf+"S7.O6", bothOK, rdy2),
		}},
	{Change: pub + "sync_method", Dir: "concurrent_c>native", PubType: tr, Procedure: "sp_changepublication", Property: "sync_method", Class: SnapshotReinit, Wide: true,
		Cites: []Cite{cite(ss+"C.concurrent_c.sync_method", "f11", rdy2)}},
	{Change: pub + "sync_method", Dir: "concurrent>concurrent_c", PubType: tr, Procedure: "sp_changepublication", Property: "sync_method", Class: SnapshotReinit, Wide: true,
		Cites: []Cite{
			cite(ss+"D.non_concurrent.sync_method_probe", "f01", non2),
			cite(ss+"D.imm_concurrent.sync_method_probe", "f11", rdy2),
			cite(ss+"D.non_concurrent_pub.change", "f01", non2),
		}},
	{Change: pub + "sync_method", Dir: "concurrent_c>concurrent", PubType: tr, Procedure: "sp_changepublication", Property: "sync_method", Class: SnapshotReinit, Wide: true,
		Cites: []Cite{cite(ss+"D.non_concurrent_pub.extend_then_change", "add=f00,extend=m_t8:14100,all:ok,change=f01", non2)}},
	{Change: pub + "sync_method", Dir: "native>character", PubType: tr, Procedure: "sp_changepublication", Property: "sync_method", Class: Snapshot,
		Cites: []Cite{cite(ss+"D.non_native.sync_method_probe", "f00", non2), cite(ss+"D.imm_native.sync_method_probe", "f10", rdy2)}},
	{Change: pub + "sync_method", Dir: "character>native", PubType: tr, Procedure: "sp_changepublication", Property: "sync_method", Class: Snapshot,
		Cites: []Cite{cite(ss+"C.character.sync_method", "f10", rdy2)}},
	{Change: pub + "sync_method", Dir: "database_snapshot>native", PubType: tr, Procedure: "sp_changepublication", Property: "sync_method", Class: Snapshot,
		Cites: []Cite{cite(ss+"C.dbsnap.sync_method", "f10", rdy2)}},
	{Change: pub + "sync_method", Dir: "native>character", PubType: sn, Procedure: "sp_changepublication", Property: "sync_method", Class: Snapshot,
		Cites: []Cite{cite(sp+"SNAP.P13", allOK, non2), cite(sp+"SNAPI.P13", invOK, rdy2)}},
	{Change: pub + "sync_method", Dir: "native>database_snapshot", PubType: sn, Procedure: "sp_changepublication", Property: "sync_method", Class: Snapshot,
		Cites: []Cite{cite(sp+"SNAP.P14", allOK, non2), cite(sp+"SNAPI.P14", invOK, rdy2)}},
	{Change: pub + "sync_method", Dir: "native>concurrent", PubType: sn, Procedure: "sp_changepublication", Property: "sync_method", Class: Refused, Error: 22547,
		Cites: []Cite{
			cite(sp+"SNAP.P12", "f00=20608,f10=20608,f01=22547,f11=22547", non2),
			cite(sp+"SNAPI.P12", "f00=20607,f10=20608,f01=20607,f11=22547", rdy2),
		}},

	// Article properties.
	{Change: art + "description", Dir: "set", PubType: tr, Procedure: "sp_changearticle", Property: "description", Class: Online,
		Cites: []Cite{cite(mx+"A01", allOK, rdy2), cite(mx+"A02", allOK, non2), cite(mx+"A23", allOK, rdy2)}},
	{Change: art + "description", Dir: "set", PubType: sn, Procedure: "sp_changearticle", Property: "description", Class: Online,
		Cites: []Cite{cite(sp+"SNAP.A01", allOK, non2), cite(sp+"SNAP.A02", allOK, non2), cite(sp+"SNAPI.A01", allOK, rdy2), cite(sp+"SNAPI.A02", allOK, rdy2)}},

	{Change: art + "destination.name", Dir: "set", PubType: tr, Procedure: "sp_changearticle", Property: "dest_table", Class: SnapshotReinit,
		Cites: []Cite{cite(mx+"A03", bothOK, rdy2), cite(mx+"A04", reinitOK, non2)}},
	{Change: art + "destination.name", Dir: "set", PubType: sn, Procedure: "sp_changearticle", Property: "dest_table", Class: SnapshotReinit,
		Cites: []Cite{cite(sp+"SNAP.A03", reinitOK, non2), cite(sp+"SNAP.A04", reinitOK, non2), cite(sp+"SNAPI.A03", bothOK, rdy2), cite(sp+"SNAPI.A04", bothOK, rdy2)}},
	{Change: art + "destination.schema", Dir: "set", PubType: tr, Procedure: "sp_changearticle", Property: "destination_owner", Class: SnapshotReinit,
		Cites: []Cite{cite(mx+"A05", bothOK, rdy2)}},
	{Change: art + "destination.schema", Dir: "set", PubType: sn, Procedure: "sp_changearticle", Property: "destination_owner", Class: SnapshotReinit,
		Cites: []Cite{cite(sp+"SNAP.A05", reinitOK, non2), cite(sp+"SNAPI.A05", bothOK, rdy2)}},

	{Change: art + "commands.insert", PubType: tr, Procedure: "sp_changearticle", Property: "ins_cmd", Class: Online,
		Cites: []Cite{cite(mx+"A06", allOK, rdy2), cite(mx+"A07", allOK, non2), cite(sp+"TWIN.A01", allOK, non2), cite(sp+"TWIN.A02", allOK, non2)}},
	{Change: art + "commands.insert", PubType: sn, Procedure: "sp_changearticle", Property: "ins_cmd", Class: SnapshotReinit,
		Cites: []Cite{cite(sp+"SNAP.A06", reinitOK, non2), cite(sp+"SNAP.A07", reinitOK, non2), cite(sp+"SNAPI.A06", bothOK, rdy2), cite(sp+"SNAPI.A07", bothOK, rdy2)}},
	{Change: art + "commands.update", PubType: tr, Procedure: "sp_changearticle", Property: "upd_cmd", Class: Online,
		Cites: []Cite{cite(mx+"A08", allOK, rdy2), cite(sp+"TWIN.A03", allOK, non2)}},
	{Change: art + "commands.update", PubType: sn, Procedure: "sp_changearticle", Property: "upd_cmd", Class: SnapshotReinit,
		Cites: []Cite{cite(sp+"SNAP.A08", reinitOK, non2), cite(sp+"SNAPI.A08", bothOK, rdy2)}},
	{Change: art + "commands.delete", PubType: tr, Procedure: "sp_changearticle", Property: "del_cmd", Class: Online,
		Cites: []Cite{cite(mx+"A09", allOK, rdy2), cite(sp+"TWIN.A04", allOK, non2)}},
	{Change: art + "commands.delete", PubType: sn, Procedure: "sp_changearticle", Property: "del_cmd", Class: SnapshotReinit,
		Cites: []Cite{cite(sp+"SNAP.A09", reinitOK, non2), cite(sp+"SNAPI.A09", bothOK, rdy2)}},

	{Change: art + "pre_creation_cmd", PubType: tr, Procedure: "sp_changearticle", Property: "pre_creation_cmd", Class: SnapshotReinit,
		Cites: []Cite{cite(mx+"A10", bothOK, rdy2), cite(mx+"A11", reinitOK, non2)}},
	{Change: art + "pre_creation_cmd", PubType: sn, Procedure: "sp_changearticle", Property: "pre_creation_cmd", Class: SnapshotReinit,
		Cites: []Cite{cite(sp+"SNAP.A10", reinitOK, non2), cite(sp+"SNAP.A11", reinitOK, non2), cite(sp+"SNAPI.A10", bothOK, rdy2), cite(sp+"SNAPI.A11", bothOK, rdy2)}},

	{Change: art + "schema_options", PubType: tr, Procedure: "sp_changearticle", Property: "schema_option", Class: SnapshotReinit,
		Cites: cat([]Cite{
			cite(mx+"A12", bothOK, rdy2), cite(mx+"A13", reinitOK, non2),
			cite(sf+"S1.O3", bothOK, rdy2), cite(sf+"S3.O3", reinitOK, non2), cite(sf+"S4.O3", allOK, non1),
			// The reinit condition is the operated article's row: S5.O3 is at
			// 2 among rows at 1 and 2, S6.O3 at 1 among rows at 1 and 2.
			cite(sf+"S5.O3", reinitOK, non2), cite(sf+"S6.O3", allOK, non1),
		}, scopeC("schema_option", "f11"))},
	{Change: art + "schema_options", PubType: sn, Procedure: "sp_changearticle", Property: "schema_option", Class: SnapshotReinit,
		Cites: []Cite{cite(sp+"SNAP.A12", reinitOK, non2), cite(sp+"SNAP.A13", reinitOK, non2), cite(sp+"SNAPI.A12", bothOK, rdy2), cite(sp+"SNAPI.A13", bothOK, rdy2)}},

	{Change: art + "insert_column_names", Dir: "to_true", PubType: tr, Procedure: "sp_changearticle", Property: "status", Class: Online,
		Cites: []Cite{cite(mx+"A14", allOK, rdy2), cite(mx+"A15", allOK, non2)}},
	{Change: art + "insert_column_names", Dir: "to_false", PubType: tr, Procedure: "sp_changearticle", Property: "status", Class: Online,
		Cites: []Cite{cite(rv+"RV.I.status.no_column_names", allOK, rdy2), cite(rv+"RV.N.status.no_column_names", allOK, non2)}},
	{Change: art + "insert_column_names", Dir: "to_true", PubType: sn, Procedure: "sp_changearticle", Property: "status", Class: Online,
		Cites: []Cite{cite(sp+"SNAP.A14", allOK, non2), cite(sp+"SNAP.A15", allOK, non2), cite(sp+"SNAPI.A14", allOK, rdy2), cite(sp+"SNAPI.A15", allOK, rdy2)}},

	{Change: art + "parameterized", Dir: "to_false", PubType: tr, Procedure: "sp_changearticle", Property: "status", Class: Online,
		Cites: []Cite{cite(mx+"A16", allOK, rdy2)}},
	{Change: art + "parameterized", Dir: "to_true", PubType: tr, Procedure: "sp_changearticle", Property: "status", Class: Online,
		Cites: []Cite{cite(rv+"RV.I.status.parameters", allOK, rdy2), cite(rv+"RV.N.status.parameters", allOK, non2)}},
	{Change: art + "parameterized", Dir: "to_false", PubType: sn, Procedure: "sp_changearticle", Property: "status", Class: Online,
		Cites: []Cite{cite(sp+"SNAP.A16", allOK, non2), cite(sp+"SNAPI.A16", allOK, rdy2)}},

	{Change: art + "creation_script", Dir: "set", PubType: tr, Procedure: "sp_changearticle", Property: "creation_script", Class: Snapshot,
		Cites: []Cite{cite(mx+"A18", invOK, rdy2)}},
	{Change: art + "creation_script", Dir: "clear", PubType: tr, Procedure: "sp_changearticle", Property: "creation_script", Class: Snapshot,
		Cites: []Cite{
			cite(rv+"RV.I.creation_script.empty", invOK, rdy2), cite(rv+"RV.I.creation_script.null", invOK, rdy2),
			cite(rv+"RV.N.creation_script.empty", allOK, non2), cite(rv+"RV.N.creation_script.null", allOK, non2),
		}},
	{Change: art + "creation_script", Dir: "set", PubType: sn, Procedure: "sp_changearticle", Property: "creation_script", Class: Snapshot,
		Cites: []Cite{cite(sp+"SNAP.A18", allOK, non2), cite(sp+"SNAPI.A18", invOK, rdy2)}},

	{Change: art + "fire_triggers_on_snapshot", Dir: "to_true", PubType: tr, Procedure: "sp_changearticle", Property: "fire_triggers_on_snapshot", Class: Online,
		Cites: []Cite{cite(mx+"A19", allOK, rdy2)}},
	{Change: art + "fire_triggers_on_snapshot", Dir: "to_false", PubType: tr, Procedure: "sp_changearticle", Property: "fire_triggers_on_snapshot", Class: Online,
		Cites: []Cite{cite(rv+"RV.I.fire_triggers_on_snapshot", allOK, rdy2), cite(rv+"RV.N.fire_triggers_on_snapshot", allOK, non2)}},
	{Change: art + "fire_triggers_on_snapshot", Dir: "to_true", PubType: sn, Procedure: "sp_changearticle", Property: "fire_triggers_on_snapshot", Class: Online,
		Cites: []Cite{cite(sp+"SNAP.A19", allOK, non2), cite(sp+"SNAPI.A19", allOK, rdy2)}},

	{Change: art + "sync_object", Dir: "set", PubType: tr, Procedure: "sp_changearticle", Property: "sync_object", Class: Snapshot,
		Cites: []Cite{cite(mx+"A20", invOK, rdy2)}},
	{Change: art + "sync_object", Dir: "set", PubType: sn, Procedure: "sp_changearticle", Property: "sync_object", Class: Snapshot,
		Cites: []Cite{cite(sp+"SNAP.A20", allOK, non2), cite(sp+"SNAPI.A20", invOK, rdy2)}},

	// type: the logbased variants only.
	{Change: art + "type", PubType: tr, Procedure: "sp_changearticle", Property: "type", Class: SnapshotReinit,
		Cites: []Cite{cite(mx+"A21", bothOK, rdy2)}},
	{Change: art + "type", PubType: sn, Procedure: "sp_changearticle", Property: "type", Class: SnapshotReinit,
		Cites: []Cite{cite(sp+"SNAP.A21", reinitOK, non2), cite(sp+"SNAPI.A21", bothOK, rdy2)}},

	// Structural operations: the class decides the flags; the costs are
	// R34's, computed in finish.
	{Change: OpAddArticle, PubType: tr, Class: Snapshot,
		Cites: cat([]Cite{
			cite(sf+"S1.O1", add2Inv, rdy2), cite(sf+"S2.O1", add2OK, non1),
			cite(sf+"S3.O1", add2OK, non2), cite(sf+"S7.O1", add2Inv, rdy2),
		}, scopeC("addarticle", "f10"))},
	{Change: OpDropArticle, PubType: tr, Class: Snapshot,
		Cites: cat([]Cite{
			cite(sf+"S1.O2", add2Inv, rdy2), cite(sf+"S2.O2", add2OK, non1),
			cite(sf+"S3.O2", add2OK, non2), cite(sf+"S7.O2", add2Inv, rdy2),
			cite(st+"C2.imm-conc", "dropsub=ok,droparticle=ok", rdy2), cite(st+"C2.imm-native", "dropsub=ok,droparticle=ok", rdy2),
			cite(st+"C2.nonimm-conc", "dropsub=ok,droparticle=ok", non2), cite(st+"C2.nonimm-native", "dropsub=ok,droparticle=ok", non2),
		}, scopeC("droparticle", "f10"))},
	{Change: OpArticleFilter, PubType: tr, Class: SnapshotReinit,
		Cites: cat([]Cite{
			cite(mx+"F01", bothOK, rdy2), cite(mx+"F02", bothOK, rdy2), cite(mx+"F03", bothOK, rdy2),
			// The filter procedure changes only through sp_articlefilter;
			// sp_changearticle filter (A22, the same procedure set again) is
			// never generated and only supports the flags of this entry.
			cite(mx+"A22", bothOK, rdy2),
			cite(sf+"S1.O7", bothOK, rdy2), cite(sf+"S3.O7", reinitOK, non2), cite(sf+"S4.O7", allOK, non1),
		}, scopeC("articlefilter", "f11"))},
	{Change: OpArticleFilter, PubType: sn, Class: SnapshotReinit,
		Cites: []Cite{
			cite(sp+"SNAP.F01", reinitOK, non2), cite(sp+"SNAP.F04", reinitOK, non2), cite(sp+"SNAP.F05", reinitOK, non2),
			cite(sp+"SNAPI.F01", bothOK, rdy2), cite(sp+"SNAPI.F04", bothOK, rdy2), cite(sp+"SNAPI.F05", bothOK, rdy2),
			// sp_changearticle filter, never generated (see the transactional entry).
			cite(sp+"SNAP.A22", reinitOK, non2), cite(sp+"SNAPI.A22", bothOK, rdy2),
		}},
	{Change: OpArticleView, PubType: tr, Class: SnapshotReinit,
		Cites: cat([]Cite{
			cite(sf+"S1.O8", bothOK, rdy2), cite(sf+"S3.O8", reinitOK, non2), cite(sf+"S4.O8", allOK, non1),
			cite(fv+"F2bs", "ok", non2), cite(fv+"F2bu", "ok", non1),
		}, scopeC("articleview", "f11"))},
	{Change: OpArticleColumn, PubType: tr, Class: SnapshotReinit,
		Cites: cat([]Cite{
			cite(mx+"F04", bothOK, rdy2), cite(mx+"F05", bothOK, rdy2), cite(mx+"F06", reinitOK, non2),
			cite(sf+"S1.O9", bothOK, rdy2), cite(sf+"S3.O9", reinitOK, non2), cite(sf+"S4.O9", allOK, non1),
		}, scopeC("articlecolumn", "f11"))},
	{Change: OpArticleColumn, PubType: sn, Class: SnapshotReinit,
		Cites: []Cite{
			cite(sp+"SNAP.F02", reinitOK, non2), cite(sp+"SNAP.F03", reinitOK, non2), cite(sp+"SNAP.F06", reinitOK, non2),
			cite(sp+"SNAPI.F02", bothOK, rdy2), cite(sp+"SNAPI.F03", bothOK, rdy2), cite(sp+"SNAPI.F06", bothOK, rdy2),
		}},

	{Change: OpAddSubscription, PubType: tr, Class: Online,
		Cites: []Cite{
			cite(st+"C1.imm-conc", "ok", rdy1), cite(st+"C1.imm-native", "ok", rdy1),
			cite(st+"C1.nonimm-conc", "ok", non1), cite(st+"C1.nonimm-native", "ok", non1),
		}},
	{Change: OpExtendSubscription, PubType: tr, Class: Online,
		Cites: []Cite{
			cite(st+"C4.nonimm-native", "addarticle=ok,extend=ok", non1), cite(st+"C4.nonimm-conc", "addarticle=ok,extend=ok", non1),
			cite(ss+"D.non_native.extend_rule", "ok", non1), cite(ss+"D.non_concurrent.extend_rule", "ok", non1),
		},
		Counter: []Cite{
			cite(ss+"D.imm_native.extend_rule", "14122", non1),
			cite(ss+"D.non_native_pub.extend", "m_t7:14100,all:ok", non1),
			cite(ss+"D.non_concurrent_pub.extend", "m_t7:14100,all:ok", non1),
			cite(ss+"D.imm_concurrent.extend_rule", "14058", non1),
			cite(ss+"D.imm_native.extend_all", "14058", non1),
		}},
	{Change: OpDropSubscription, PubType: tr, Class: Online, Cites: dropSubscriptionCites},
	{Change: OpDropSubscriptionArticle, PubType: tr, Class: Online, Cites: dropSubscriptionCites},
	{Change: OpDropPublication, PubType: tr, Class: Online, Cites: dropPublicationCites},

	// Distributor.
	{Change: "distributor.min_retention_hours", PubType: tr, Procedure: "sp_changedistributiondb", Property: "min_distretention", Class: Online,
		Cites: []Cite{cite(ch+"DST.sp_changedistributiondb.min_distretention", "ok", non1)}},
	{Change: "distributor.max_retention_hours", PubType: tr, Procedure: "sp_changedistributiondb", Property: "max_distretention", Class: Online,
		Cites: []Cite{cite(ch+"DST.sp_changedistributiondb.max_distretention", "ok", non1)}},
	{Change: "distributor.history_retention_hours", PubType: tr, Procedure: "sp_changedistributiondb", Property: "history_retention", Class: Online,
		Cites: []Cite{cite(ch+"DST.sp_changedistributiondb.history_retention", "ok", non1)}},
	{Change: "distributor.working_directory", Dir: "set", PubType: tr, Procedure: "sp_changedistpublisher", Property: "working_directory", Class: Online,
		Cites: []Cite{cite(ch+"DST.sp_changedistpublisher.working_directory", "ok", non1)}},
	{Change: "distributor.publisher_connection.security", PubType: tr, Procedure: "sp_changedistpublisher", Property: "security_mode", Class: Online,
		Cites: []Cite{cite(ch+"DST.sp_changedistpublisher.security_mode", "ok", non1)}},

	// Agents. Only the snapshot agent's schedule can change, in one call
	// passing every @frequency_* and @active_* parameter (R22).
	{Change: pub + "snapshot_agent.schedules", PubType: tr, Procedure: "sp_changepublication_snapshot", Property: "@frequency_*,@active_*", Class: Online,
		Cites: []Cite{
			cite(ch+"AGT.sp_changepublication_snapshot.frequency_type+frequency_interval", "ok", non1),
			cite(ch+"AGT.sp_changepublication_snapshot.frequency_interval", "ok", non1),
			cite(ch+"AGT.sp_changepublication_snapshot.frequency_subday", "ok", non1),
			cite(ch+"AGT.sp_changepublication_snapshot.frequency_subday_interval", "ok", non1),
			cite(ch+"AGT.sp_changepublication_snapshot.frequency_relative_interval", "ok", non1),
			cite(ch+"AGT.sp_changepublication_snapshot.frequency_recurrence_factor", "ok", non1),
			cite(ch+"AGT.sp_changepublication_snapshot.active_start_date", "ok", non1),
			cite(ch+"AGT.sp_changepublication_snapshot.active_start_time_of_day", "ok", non1),
			cite(ch+"AGT.sp_changepublication_snapshot.active_end_time_of_day", "ok", non1),
		},
		Counter: []Cite{
			cite(ch+"AGT.sp_changepublication_snapshot.frequency_type", "14278", non1),
			cite(ch+"AGT.sp_changepublication_snapshot.active_end_date", "14288", non1),
		}},
	// AGT.sp_changepublication_snapshot.snapshot_job_name has no entry:
	// job_name is not compared (R41).
	// The connection security of the log reader and snapshot agents is
	// refused (21694); job_login with 14529, since a valid account was never
	// measured.
	{Change: "publisher.log_reader_agent.connection.security", PubType: tr, Procedure: "sp_changelogreader_agent", Property: "publisher_security_mode", Class: Refused, Error: 21694,
		Cites: []Cite{cite(ch+"AGT.sp_changelogreader_agent.publisher_security_mode", "21694", non1)}},
	{Change: pub + "snapshot_agent.connection.security", PubType: tr, Procedure: "sp_changepublication_snapshot", Property: "publisher_security_mode", Class: Refused, Error: 21694,
		Cites: []Cite{cite(ch+"AGT.sp_changepublication_snapshot.publisher_security_mode", "21694", non1)}},
	{Change: "publisher.log_reader_agent.job_login", Dir: "set", PubType: tr, Procedure: "sp_changelogreader_agent", Property: "job_login", Class: Refused, Error: 14529,
		Cites: []Cite{cite(ch+"AGT.sp_changelogreader_agent.job_login", "14529", non1)}},
	{Change: pub + "snapshot_agent.job_login", Dir: "set", PubType: tr, Procedure: "sp_changepublication_snapshot", Property: "job_login", Class: Refused, Error: 14529,
		Cites: []Cite{cite(ch+"AGT.sp_changepublication_snapshot.job_login", "14529", non1)}},
	{Change: sub + "distribution_agent.job_login", Dir: "set", PubType: tr, Procedure: "sp_changesubscription", Property: "distrib_job_login", Class: Refused, Error: 14529,
		Cites: []Cite{cite(ch+"AGT.sp_changesubscription.distrib_job_login", "14529", non1)}},
	{Change: sub + "pull_agent.job_login", Dir: "set", PubType: tr, Procedure: "sp_change_subscription_properties", Property: "distrib_job_login", Class: Refused, Error: 14529,
		Cites: []Cite{cite(pl+"P2.distrib_job_login", "14529", non1)}},

	// Push subscription agents.
	{Change: sub + "distribution_agent.connection.security", PubType: tr, Procedure: "sp_changesubscription", Property: "subscriber_security_mode", Class: Online,
		Cites: []Cite{cite(ch+"SUB.subscriber_security_mode", "ok", non1)}},
	{Change: sub + "distribution_agent.subscription_streams", PubType: tr, Procedure: "sp_changesubscription", Property: "subscriptionstreams", Class: Online,
		Cites: []Cite{cite(ch+"SUB.subscriptionstreams", "ok", non1)}},
	// The row sets memory_optimized to 1 and restores it to 0.
	{Change: sub + "distribution_agent.memory_optimized", Dir: "to_true", PubType: tr, Procedure: "sp_changesubscription", Property: "memory_optimized", Class: Online,
		Cites: []Cite{cite(ch+"SUB.memory_optimized", "ok", non1)}},
	{Change: sub + "distribution_agent.memory_optimized", Dir: "to_false", PubType: tr, Procedure: "sp_changesubscription", Property: "memory_optimized", Class: Online,
		Cites: []Cite{cite(ch+"SUB.memory_optimized", "ok", non1)}},

	// Pull agents: each 08-pull P2 row sets the property, then restores it
	// (restore=ok), which measures both directions.
	{Change: sub + "pull_agent.distributor_connection.security", PubType: tr, Procedure: "sp_change_subscription_properties", Property: "distributor_security_mode", Class: Online,
		Cites: []Cite{cite(pl+"P2.distributor_security_mode", "ok", non1)}},
	{Change: sub + "pull_agent.alt_snapshot_folder", Dir: "set", PubType: tr, Procedure: "sp_change_subscription_properties", Property: "alt_snapshot_folder", Class: Online,
		Cites: []Cite{cite(pl+"P2.alt_snapshot_folder", "ok", non1)}},
	{Change: sub + "pull_agent.alt_snapshot_folder", Dir: "clear", PubType: tr, Procedure: "sp_change_subscription_properties", Property: "alt_snapshot_folder", Class: Online,
		Cites: []Cite{cite(pl+"P2.alt_snapshot_folder", "ok", non1)}},
	{Change: sub + "pull_agent.working_directory", Dir: "set", PubType: tr, Procedure: "sp_change_subscription_properties", Property: "working_directory", Class: Online,
		Cites: []Cite{cite(pl+"P2.working_directory", "ok", non1)}},
	{Change: sub + "pull_agent.working_directory", Dir: "clear", PubType: tr, Procedure: "sp_change_subscription_properties", Property: "working_directory", Class: Online,
		Cites: []Cite{cite(pl+"P2.working_directory", "ok", non1)}},
	{Change: sub + "pull_agent.use_ftp", Dir: "to_true", PubType: tr, Procedure: "sp_change_subscription_properties", Property: "use_ftp", Class: Online,
		Cites: []Cite{cite(pl+"P2.use_ftp", "ok", non1)}},
	{Change: sub + "pull_agent.use_ftp", Dir: "to_false", PubType: tr, Procedure: "sp_change_subscription_properties", Property: "use_ftp", Class: Online,
		Cites: []Cite{cite(pl+"P2.use_ftp", "ok", non1)}},
	{Change: sub + "pull_agent.distributor", Dir: "set", PubType: tr, Procedure: "sp_change_subscription_properties", Property: "distributor", Class: Online,
		Cites: []Cite{cite(pl+"P2.distributor", "ok", non1)}},
	{Change: sub + "pull_agent.memory_optimized", Dir: "to_true", PubType: tr, Procedure: "sp_change_subscription_properties", Property: "memory_optimized", Class: Online,
		Cites: []Cite{cite(pl+"P2.memory_optimized", "ok", non1)}},
	{Change: sub + "pull_agent.memory_optimized", Dir: "to_false", PubType: tr, Procedure: "sp_change_subscription_properties", Property: "memory_optimized", Class: Online,
		Cites: []Cite{cite(pl+"P2.memory_optimized", "ok", non1)}},

	// Agent profiles (R6). sp_change_agent_profile accepts description only
	// (21183 on default): a change of default of an existing profile has no
	// entry. A copied parameter is changed, never added (20067).
	{Change: "agent_profiles[*].description", Dir: "set", PubType: tr, Procedure: "sp_change_agent_profile", Property: "description", Class: Online,
		Cites:   []Cite{cite(pf+"PF.change_description", "ok", non1)},
		Counter: []Cite{cite(pf+"PF.change_default", "21183", non1)}},
	{Change: "agent_profiles[*].parameters", PubType: tr, Class: Online,
		Cites: []Cite{
			cite(pf+"PF.change_parameter", "ok", non1), cite(pf+"PF.add_parameter", "ok", non1),
			cite(pf+"PF.drop_parameter", "ok", non1),
		},
		Counter: []Cite{cite(pf+"PF.add_copied_parameter", "20067", non1)}},
	{Change: OpAddProfile, PubType: tr, Procedure: "sp_add_agent_profile", Property: "@default", Class: Online,
		Cites: []Cite{cite(pf+"PF.copied_parameters", "ok", non1), cite(pf+"PF.create_default", "ok", non1)}},
	{Change: OpProfileBinding, PubType: tr, Procedure: "[<distribution>].dbo.sp_update_agent_profile", Property: "@profile_id", Class: Online,
		Cites: []Cite{
			cite(ch+"PRF.distribution-prefix", "ok", non1),
			cite(ch+"PRF.distribution-prefix.cwd-distribution", "ok", non1),
		},
		Counter: []Cite{cite(ch+"PRF.msdb-prefix", "21482", non1), cite(ch+"PRF.plain-name", "21482", non1)}},

	// Job operations (R24).
	{Change: OpJobEnabled, PubType: tr, Procedure: "msdb.dbo.sp_update_job", Property: "@enabled", Class: Online, Notes: []string{"O20"}},
	{Change: OpJobDisable, PubType: tr, Procedure: "msdb.dbo.sp_update_job", Property: "@enabled", Class: Online, Notes: []string{"O20"}},
	{Change: OpJobRestore, PubType: tr, Procedure: "msdb.dbo.sp_update_job", Property: "@enabled", Class: Online, Notes: []string{"O20"}},
	{Change: OpJobStart, PubType: tr, Procedure: "msdb.dbo.sp_start_job", Property: "@job_id", Class: Online, Notes: []string{"O20"}},
}

var dropPublicationCites = []Cite{
	cite(st+"C5.imm-conc", "dropsub=ok,droppublication=ok", rdy2), cite(st+"C5.imm-native", "dropsub=ok,droppublication=ok", rdy2),
	cite(st+"C5.nonimm-conc", "dropsub=ok,droppublication=ok", non2), cite(st+"C5.nonimm-native", "dropsub=ok,droppublication=ok", non2),
}

var dropSubscriptionCites = cat([]Cite{
	cite(st+"C2.imm-conc", "dropsub=ok,droparticle=ok", rdy2), cite(st+"C2.imm-native", "dropsub=ok,droparticle=ok", rdy2),
	cite(st+"C2.nonimm-conc", "dropsub=ok,droparticle=ok", non2), cite(st+"C2.nonimm-native", "dropsub=ok,droparticle=ok", non2),
}, dropPublicationCites, []Cite{
	cite(pl+"P3.subscriber-first.step1", "ok", non1),
	cite(pl+"P3.subscriber-first.step2", "ok", non1),
	cite(pl+"P3.subscriber-first.cleanup", "none_needed", non1),
})
