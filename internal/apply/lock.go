package apply

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"fmt"
)

// errLocked is the lock held by another session (R45).
var errLocked = errors.New("another sqlrepl apply holds the lock")

// lockBatch takes the application lock (R45), the literal batch: without
// the DECLARE it fails with Msg 137 (panel XD). The resource is bound as
// @resource. The owner is the session, so that the lock survives a refused
// call, its ROLLBACK and a USE on the holder.
const lockBatch = "DECLARE @rc int; EXEC @rc = sp_getapplock @Resource = @resource, @LockMode = N'Exclusive', @LockOwner = N'Session', @LockTimeout = 0; SELECT @rc;"

// unlockBatch releases it and returns the return code (R45).
const unlockBatch = "DECLARE @rc int; EXEC @rc = sp_releaseapplock @Resource = @resource, @LockOwner = N'Session'; SELECT @rc;"

// lock takes resource in database on conn (R45): USE database, then
// lockBatch; a return code below 0 is errLocked.
func lock(ctx context.Context, conn *sql.Conn, database, resource string) error {
	if _, err := conn.ExecContext(ctx, "USE "+quoteName(database)+";"); err != nil {
		return fmt.Errorf("USE %s: %w", database, err)
	}
	var rc int
	if err := conn.QueryRowContext(ctx, lockBatch, sql.Named("resource", resource)).Scan(&rc); err != nil {
		return err
	}
	if rc < 0 {
		return fmt.Errorf("%w on %s (sp_getapplock returned %d)", errLocked, database, rc)
	}
	return nil
}

// unlock issues USE database itself, then releases resource and asserts
// the return code 0 (R45): released in another database, the release
// fails with Msg 1223 and -999 (panel C, XD, XN, G).
func unlock(ctx context.Context, conn *sql.Conn, database, resource string) error {
	if _, err := conn.ExecContext(ctx, "USE "+quoteName(database)+";"); err != nil {
		return fmt.Errorf("USE %s: %w", database, err)
	}
	var rc int
	if err := conn.QueryRowContext(ctx, unlockBatch, sql.Named("resource", resource)).Scan(&rc); err != nil {
		return err
	}
	if rc != 0 {
		return fmt.Errorf("sp_releaseapplock returned %d", rc)
	}
	return nil
}

// discard ends the session of conn instead of pooling it: conn.Raw with a
// function that returns driver.ErrBadConn, which database/sql takes as the
// order to close the driver connection (R45). conn is closed afterwards.
func discard(conn *sql.Conn) error {
	err := conn.Raw(func(any) error { return driver.ErrBadConn })
	if err == nil || errors.Is(err, driver.ErrBadConn) || errors.Is(err, sql.ErrConnDone) {
		// ErrConnDone: database/sql already closed it after a bad
		// connection; nothing is pooled.
		return nil
	}
	return err
}
