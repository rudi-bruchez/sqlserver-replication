package model

// SubsetAllowed reports whether a subscription may list a subset of the
// articles of the publication. A subset cannot exist when the publication
// keeps its snapshot ready for new subscriptions (immediate_sync) or builds it
// concurrently (sync_method concurrent, concurrent_c): the snapshot then
// covers every article (spec "Subscriptions").
func (p *Publication) SubsetAllowed() bool {
	if p.ImmediateSync != nil && *p.ImmediateSync {
		return false
	}
	if p.SyncMethod != nil && (*p.SyncMethod == "concurrent" || *p.SyncMethod == "concurrent_c") {
		return false
	}
	return true
}
