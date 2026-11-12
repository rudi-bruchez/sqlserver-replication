package precheck

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"math/big"
	"strings"
)

// An LSN is binary(10): 4 bytes of virtual log file, 4 of block, 2 of slot,
// big-endian, so that comparing the bytes compares the LSNs. It is the form
// sp_addsubscription @subscriptionlsn takes (10-init-modes.sh line 199).

// parseLSN reads an LSN as the file writes it: 0x and 20 hexadecimal
// digits.
func parseLSN(s string) ([10]byte, error) {
	var b [10]byte
	digits, ok := strings.CutPrefix(s, "0x")
	if !ok || len(digits) != 20 {
		return b, fmt.Errorf("%q is not 0x and 20 hexadecimal digits", s)
	}
	if _, err := hex.Decode(b[:], []byte(digits)); err != nil {
		return b, fmt.Errorf("%q is not 0x and 20 hexadecimal digits", s)
	}
	return b, nil
}

var (
	ten5  = big.NewInt(100000)
	ten15 = new(big.Int).Exp(big.NewInt(10), big.NewInt(15), nil)
)

// lsnFromNumeric converts backupset.last_lsn, a numeric(25,0) read as text,
// with the arithmetic of 10-init-modes.sh lines 194 to 199: vlf = lsn /
// 10^15, block = (lsn % 10^15) / 10^5, slot = lsn % 10^5. A field that does
// not fit its bytes is an error, and the bytes are checked to give the
// numeric back (the round trip of the script).
func lsnFromNumeric(s string) ([10]byte, error) {
	var b [10]byte
	n, ok := new(big.Int).SetString(s, 10)
	if !ok || n.Sign() < 0 || strings.ContainsAny(s, "+-") {
		return b, fmt.Errorf("last_lsn %q is not a non-negative integer", s)
	}
	vlf, rest := new(big.Int).QuoRem(n, ten15, new(big.Int))
	block, slot := new(big.Int).QuoRem(rest, ten5, new(big.Int))
	if !vlf.IsUint64() || vlf.Uint64() > 0xFFFFFFFF || block.Uint64() > 0xFFFFFFFF || slot.Uint64() > 0xFFFF {
		return b, fmt.Errorf("last_lsn %s: vlf %s, block %s, slot %s do not fit binary(10)", s, vlf, block, slot)
	}
	binary.BigEndian.PutUint32(b[0:4], uint32(vlf.Uint64()))
	binary.BigEndian.PutUint32(b[4:8], uint32(block.Uint64()))
	binary.BigEndian.PutUint16(b[8:10], uint16(slot.Uint64()))
	back := new(big.Int).Mul(big.NewInt(int64(binary.BigEndian.Uint32(b[0:4]))), ten15)
	back.Add(back, new(big.Int).Mul(big.NewInt(int64(binary.BigEndian.Uint32(b[4:8]))), ten5))
	back.Add(back, big.NewInt(int64(binary.BigEndian.Uint16(b[8:10]))))
	if back.Cmp(n) != 0 {
		return b, fmt.Errorf("last_lsn %s converts to %X, which gives %s back", s, b, back)
	}
	return b, nil
}

// lsnFromLogEnd reads sys.dm_db_log_stats.log_end_lsn, written
// vlf:block:slot in 8, 8 and 4 hexadecimal digits (20-apply
// AP.lsn.log_end_format).
func lsnFromLogEnd(s string) ([10]byte, error) {
	var b [10]byte
	parts := strings.Split(s, ":")
	if len(parts) != 3 || len(parts[0]) != 8 || len(parts[1]) != 8 || len(parts[2]) != 4 {
		return b, fmt.Errorf("log_end_lsn %q is not xxxxxxxx:xxxxxxxx:xxxx", s)
	}
	if _, err := hex.Decode(b[:], []byte(strings.Join(parts, ""))); err != nil {
		return b, fmt.Errorf("log_end_lsn %q is not xxxxxxxx:xxxxxxxx:xxxx", s)
	}
	return b, nil
}

// checkLSN is R57's check of an LSN against the last_lsn of the backup the
// subscriber database was restored from and the end of the publication
// database's log: not zero, not beyond the log end, and equal to the
// backup's last_lsn, the only value 10-init-modes measured to work for a
// creation (I3.lsn.create). A value above it skips commands silently
// (panel C); one below replays delivered rows (I3.lsn.gap-original,
// 14151). This guards against the measured failure, a wrong LSN accepted
// silently that stops every subscription of the database; it is not a proof
// that the subscriber holds what the LSN says.
func checkLSN(lsn, restored, logEnd [10]byte) (ok bool, reason string) {
	switch {
	case lsn == [10]byte{}:
		return false, "the LSN is zero"
	case bytes.Compare(lsn[:], logEnd[:]) > 0:
		return false, fmt.Sprintf("0x%X is beyond the end of the log of the publication database, 0x%X", lsn, logEnd)
	case bytes.Compare(lsn[:], restored[:]) < 0:
		return false, fmt.Sprintf("0x%X is below the last_lsn 0x%X of the backup the subscriber database was restored from: the subscriber would receive changes it already holds", lsn, restored)
	case bytes.Compare(lsn[:], restored[:]) > 0:
		return false, fmt.Sprintf("0x%X is above the last_lsn 0x%X of the backup the subscriber database was restored from: the changes between them would be skipped silently", lsn, restored)
	}
	return true, ""
}
