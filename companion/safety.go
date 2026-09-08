package main

import (
	"context"
	"fmt"
	"log"

	"github.com/jackc/pglogrepl"
	"github.com/jackc/pgx/v5/pgconn"
)

// A replication slot retains WAL until its consumer catches up. If the
// companion stops, or falls far enough behind, that retention fills the disk
// and stops the database.
//
// That is worse than the problem the companion exists to solve: losing some
// archived history is recoverable, a database that will not start is an
// outage. So at a hard ceiling the slot is advanced and the skipped range is
// recorded as a gap -- the same principle as retention and erasure, where
// lawful loss is written down rather than hidden.
type SlotGuard struct {
	meta      *pgconn.PgConn
	repl      *pgconn.PgConn
	slot      string
	warnBytes int64
	maxBytes  int64
	arch      *Archive
	onGap     func(from, to pglogrepl.LSN, reason, detail string) error
	warned    bool
}

func (g *SlotGuard) Check(ctx context.Context, confirmed pglogrepl.LSN) error {
	res := g.meta.ExecParams(ctx, `
		SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)::bigint,
		       pg_current_wal_lsn()::text
		FROM pg_replication_slots WHERE slot_name = $1`,
		[][]byte{[]byte(g.slot)}, nil, nil, nil).Read()
	if res.Err != nil {
		return res.Err
	}
	if len(res.Rows) == 0 {
		return fmt.Errorf("slot %s has disappeared -- nothing is being archived", g.slot)
	}

	var retained int64
	if _, err := fmt.Sscan(string(res.Rows[0][0]), &retained); err != nil {
		return err
	}
	current, err := pglogrepl.ParseLSN(string(res.Rows[0][1]))
	if err != nil {
		return err
	}

	switch {
	case g.maxBytes > 0 && retained >= g.maxBytes:
		log.Printf("SAFETY VALVE: slot %s retains %d bytes of WAL, past the %d ceiling",
			g.slot, retained, g.maxBytes)
		log.Printf("advancing the slot to %s and recording the skipped range as a gap; "+
			"the alternative is letting the disk fill and the database stop", current)

		if err := g.arch.Append(Change{
			LSN: current.String(), Gap: true,
			FromLSN: confirmed.String(), ToLSN: current.String(),
			Reason: "slot advanced by the safety valve: retained WAL past the ceiling",
		}); err != nil {
			return err
		}
		if err := g.arch.Rotate(); err != nil {
			return err
		}
		if g.onGap != nil {
			if err := g.onGap(confirmed, current,
				"safety valve advanced the slot",
				fmt.Sprintf("%d bytes retained, ceiling %d", retained, g.maxBytes)); err != nil {
				return err
			}
		}
		return pglogrepl.SendStandbyStatusUpdate(ctx, g.replConn(),
			pglogrepl.StandbyStatusUpdate{WALWritePosition: current})

	case g.warnBytes > 0 && retained >= g.warnBytes:
		if !g.warned {
			log.Printf("WARNING: slot %s retains %d bytes of WAL (warn at %d, ceiling %d)",
				g.slot, retained, g.warnBytes, g.maxBytes)
			g.warned = true
		}
	default:
		g.warned = false
	}
	return nil
}

// The guard needs the replication connection only to advance the slot, and is
// given it late so that Check can be unit-reasoned about without one.
func (g *SlotGuard) replConn() *pgconn.PgConn { return g.repl }
