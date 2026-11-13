package apply

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"
)

// The folder rule of R50 (panel C, amended by the controller in fix round
// 1 of Task 8): a publication's snapshot folder is found from its own path,
// never from a "Delivered snapshot" line, which a shared agent writes for
// every publication it serves. The listing is sys.dm_os_enumerate_filesystem
// of the snapshot root (Task 3, row DL.listing and lab/README.md
// "Deliveries"): recursive, levels counted from the children of the folder
// listed, so that a level number moves with the argument and is never
// matched on. The folder is the one directory whose parent_directory is
// <root>/unc/ and whose whole name is <PUBLISHER>_<DB>_<PUB> without regard
// to case (SQL Server writes it upper-cased, spaces kept), PUBLISHER the
// publisher's name, which Build has checked equal to its @@SERVERNAME
// without regard to case (R7); its runs are the directories whose
// parent_directory is the folder's full path. A suffix _<DB>_<PUB> is not
// enough: folder names are not unique by suffix (x_m_db_m_p of m_db has the
// folder REPLLAB_M_DB_X_M_DB_M_P, which ends with _M_DB_M_P, and two
// publishers with the same database and publication names share a root).
// The folder form of a named instance (SRV\INST) is not measured: such a
// publisher's folder is never identified. Separators are matched whatever
// they are, / or \: the Linux lab writes /, and a Windows distributor is
// not measured.

// fsEntry is one row of the listing, the columns of DL.listing the rule
// uses.
type fsEntry struct {
	FullPath string // full_filesystem_path, without a trailing separator
	Parent   string // parent_directory, with a trailing separator on the lab
	Name     string // file_or_directory_name, without its parent
	IsDir    bool   // is_directory
}

// errNoFolder is the publication's folder absent from the listing: for a
// publication that exists before the plan, the delivery is unconfirmed; for
// one the plan creates, an empty listing (R50).
var errNoFolder = errors.New("no snapshot folder")

func isNoFolder(err error) bool { return errors.Is(err, errNoFolder) }

// noFolderError keeps the message R50 prints and tells errNoFolder.
type noFolderError struct{ publication, path string }

func (e noFolderError) Error() string {
	return fmt.Sprintf("snapshot folder of %s cannot be listed at %s", e.publication, e.path)
}

func (e noFolderError) Unwrap() error { return errNoFolder }

// samePath compares two paths of the distributor: separators / and \ are
// one, a trailing separator is ignored, and case is ignored (a Windows
// path is written in any case; two Linux folders that differ only in case
// under one root are not expected).
func samePath(a, b string) bool { return strings.EqualFold(normPath(a), normPath(b)) }

func normPath(p string) string {
	return strings.TrimRight(strings.ReplaceAll(p, `\`, "/"), "/")
}

// pubFolder is the full path of the publication's folder in a listing of
// root: the one directory whose parent is <root>/unc and whose name is
// <publisher>_<database>_<publication>, without regard to case. None is an
// errNoFolder, "snapshot folder of <publication> cannot be listed at
// <root>"; several (names differing in case) are "snapshot folder of
// <publication> not identified", and so is a publisher name with a \ (a
// named instance, whose folder form is not measured).
func pubFolder(entries []fsEntry, root, publisher, database, publication string) (string, error) {
	if strings.Contains(publisher, `\`) {
		return "", fmt.Errorf("snapshot folder of %s not identified: the folder form of a named instance is not measured", publication)
	}
	unc := normPath(root) + "/unc"
	name := publisher + "_" + database + "_" + publication
	var found []string
	for _, e := range entries {
		if e.IsDir && samePath(e.Parent, unc) && strings.EqualFold(e.Name, name) {
			found = append(found, e.FullPath)
		}
	}
	switch len(found) {
	case 0:
		return "", noFolderError{publication: publication, path: root}
	case 1:
		return found[0], nil
	}
	return "", fmt.Errorf("snapshot folder of %s not identified", publication)
}

// runFolders is the names of the directories whose parent is folderPath,
// sorted: the runs of that publication folder, never another's, nor a
// file.
func runFolders(entries []fsEntry, folderPath string) []string {
	var runs []string
	for _, e := range entries {
		if e.IsDir && samePath(e.Parent, folderPath) {
			runs = append(runs, e.Name)
		}
	}
	sort.Strings(runs)
	return runs
}

// folderName is the last element of a folder's full path.
func folderName(path string) string {
	p := normPath(path)
	return p[strings.LastIndex(p, "/")+1:]
}

// listRoot reads the listing of root on the distributor's pinned
// connection (qListing).
func listRoot(ctx context.Context, s *session, distributor, root string) ([]fsEntry, error) {
	conn, err := s.conn(ctx, distributor)
	if err != nil {
		return nil, err
	}
	rows, err := conn.QueryContext(ctx, qListing, root)
	if err != nil {
		return nil, fmt.Errorf("list %s: %w", root, err)
	}
	defer rows.Close()
	var entries []fsEntry
	for rows.Next() {
		var e fsEntry
		var isDir int
		if err := rows.Scan(&e.FullPath, &e.Parent, &e.Name, &isDir); err != nil {
			return nil, fmt.Errorf("list %s: %w", root, err)
		}
		e.IsDir = isDir == 1
		entries = append(entries, e)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("list %s: %w", root, err)
	}
	return entries, nil
}
