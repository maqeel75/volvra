// volvra-companion -- the durable tier.
//
// The trigger tier shares fate with the database: it makes mistakes
// recoverable, but it is not a backup. This process reads a logical
// replication slot and writes change data to storage the customer owns, so the
// history survives the database itself.
//
// Two requirements the trigger tier does not have:
//
//	wal_level = logical    on the server
//	REPLICA IDENTITY FULL  on covered tables, so the WAL carries before images
//
// Run volvra.companion_setup() first; it does the second and tells you about
// the first.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/jackc/pglogrepl"
	"github.com/jackc/pgx/v5/pgconn"
)

const usage = `volvra-companion -- durable change archive for PostgreSQL

  volvra-companion run     --dsn DSN --archive DIR [--slot NAME] [--publication NAME]
                           [--segment-bytes N] [--lag-warn N] [--lag-max N]
  volvra-companion verify  --archive DIR
  volvra-companion restore --archive DIR --dsn DSN [--dry-run]
  volvra-companion status  --dsn DSN

The archive is newline-delimited JSON in numbered segments, described by a
manifest that chains their SHA-256 hashes. It is readable without this binary
and without the database -- which is the point of it.

A replication slot retains WAL until it is consumed. If this process stops, the
database keeps WAL for it. --lag-max is the ceiling at which the slot is
advanced and the skipped range recorded as a gap, because a database that will
not start is worse than a hole you know about.
`

func main() {
	log.SetFlags(log.Ltime)
	if len(os.Args) < 2 {
		fmt.Print(usage)
		os.Exit(2)
	}

	cmd := os.Args[1]
	fs := flag.NewFlagSet(cmd, flag.ExitOnError)
	dsn := fs.String("dsn", os.Getenv("VOLVRA_DSN"), "libpq connection string (or VOLVRA_DSN)")
	archive := fs.String("archive", "", "archive directory")
	slot := fs.String("slot", "volvra_companion", "logical replication slot")
	pub := fs.String("publication", "volvra_pub", "publication to stream")
	segBytes := fs.Int64("segment-bytes", 64<<20, "rotate a segment at this size")
	lagWarn := fs.Int64("lag-warn", 512<<20, "warn when the slot retains this much WAL")
	lagMax := fs.Int64("lag-max", 5<<30, "advance the slot past this, recording a gap")
	dry := fs.Bool("dry-run", false, "restore: parse and count, change nothing")
	_ = fs.Parse(os.Args[2:])

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	var err error
	switch cmd {
	case "run":
		err = cmdRun(ctx, *dsn, *archive, *slot, *pub, *segBytes, *lagWarn, *lagMax)
	case "verify":
		err = cmdVerify(*archive)
	case "restore":
		err = cmdRestore(ctx, *archive, *dsn, *dry)
	case "status":
		err = cmdStatus(ctx, *dsn)
	case "help", "-h", "--help":
		fmt.Print(usage)
		return
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n\n%s", cmd, usage)
		os.Exit(2)
	}
	if err != nil {
		log.Fatalf("error: %v", err)
	}
}

func require(name, v string) error {
	if v == "" {
		return fmt.Errorf("--%s is required", name)
	}
	return nil
}

func cmdRun(ctx context.Context, dsn, dir, slot, pub string,
	segBytes, lagWarn, lagMax int64) error {

	if err := require("dsn", dsn); err != nil {
		return err
	}
	if err := require("archive", dir); err != nil {
		return err
	}

	arch, err := OpenArchive(dir, slot, pub, segBytes)
	if err != nil {
		return err
	}
	defer arch.Close()

	st, err := NewStreamer(ctx, dsn, slot, pub, arch, nil)
	if err != nil {
		return err
	}
	defer st.Close(context.Background())

	// Resume from what the archive actually holds, never from what the slot
	// thinks: the archive is the authority on what is durable.
	start, err := st.EnsureSlot(ctx)
	if err != nil {
		return err
	}
	if l := arch.ResumeLSN(); l != "" {
		if p, perr := pglogrepl.ParseLSN(l); perr == nil && p > start {
			log.Printf("archive already holds up to %s, resuming there", p)
			start = p
		}
	}

	abs, _ := filepath.Abs(dir)
	st.guard = &SlotGuard{
		meta: st.meta, repl: st.repl, slot: slot,
		warnBytes: lagWarn, maxBytes: lagMax, arch: arch,
		onGap: func(from, to pglogrepl.LSN, reason, detail string) error {
			res := st.meta.ExecParams(ctx,
				"SELECT volvra.companion_record_gap($1,$2,$3,$4,$5)",
				[][]byte{[]byte(slot), []byte(from.String()), []byte(to.String()),
					[]byte(reason), []byte(detail)}, nil, nil, nil).Read()
			return res.Err
		},
	}

	report := func(l pglogrepl.LSN) {
		segs, changes := arch.Stats()
		res := st.meta.ExecParams(ctx,
			"SELECT volvra.companion_report($1,$2,$3,$4,$5)",
			[][]byte{[]byte(slot), []byte(l.String()),
				[]byte(fmt.Sprint(segs)), []byte(fmt.Sprint(changes)),
				[]byte(abs)}, nil, nil, nil).Read()
		if res.Err != nil {
			// Reporting is observability, not durability: the archive is
			// already on disk, so a database that will not take the checkpoint
			// must not stop the stream.
			log.Printf("note: could not record checkpoint: %v", res.Err)
		}
	}

	log.Printf("archiving slot %s to %s", slot, abs)
	err = st.Run(ctx, start, report)
	if cerr := arch.Close(); cerr != nil && err == nil {
		err = cerr
	}
	if err == nil {
		segs, changes := arch.Stats()
		log.Printf("stopped cleanly: %d segment(s), %d change(s) archived", segs, changes)
	}
	return err
}

func cmdVerify(dir string) error {
	if err := require("archive", dir); err != nil {
		return err
	}
	findings, m, err := VerifyArchive(dir)
	if err != nil {
		return err
	}

	var changes int64
	for _, s := range m.Segments {
		changes += s.Changes
	}
	fmt.Printf("archive  %s\n", dir)
	fmt.Printf("slot     %s\n", m.Slot)
	fmt.Printf("segments %d\n", len(m.Segments))
	fmt.Printf("changes  %d\n", changes)

	if len(findings) == 0 {
		fmt.Println("\nEvery segment matches its manifest entry, and the chain is intact.")
		return nil
	}
	fmt.Printf("\n%d problem(s):\n", len(findings))
	for _, f := range findings {
		fmt.Printf("  segment %-4d %-16s %s\n", f.Segment, f.Verdict, f.Detail)
	}
	return fmt.Errorf("archive verification failed")
}

func cmdRestore(ctx context.Context, dir, dsn string, dry bool) error {
	if err := require("archive", dir); err != nil {
		return err
	}
	if !dry {
		if err := require("dsn", dsn); err != nil {
			return err
		}
	}

	// Never load an archive that does not verify: a restore is exactly the
	// moment its integrity matters.
	findings, _, err := VerifyArchive(dir)
	if err != nil {
		return err
	}
	if len(findings) > 0 {
		for _, f := range findings {
			fmt.Fprintf(os.Stderr, "  segment %-4d %-16s %s\n", f.Segment, f.Verdict, f.Detail)
		}
		return fmt.Errorf("refusing to restore an archive that does not verify")
	}

	loaded, skipped, err := RestoreArchive(ctx, dir, dsn, dry)
	if err != nil {
		return err
	}
	what := "loaded into volvra.change_log"
	if dry {
		what = "would be loaded (dry run)"
	}
	fmt.Printf("%d change(s) %s, %d skipped (gaps and truncates carry no row image)\n",
		loaded, what, skipped)
	if !dry {
		fmt.Println("\nUndo them the ordinary way, with the conflict guard and the cap:")
		fmt.Println("  SELECT * FROM volvra.preview_undo('your_table', <from>, <to>);")
	}
	return nil
}

func cmdStatus(ctx context.Context, dsn string) error {
	if err := require("dsn", dsn); err != nil {
		return err
	}
	conn, err := pgconn.Connect(ctx, dsn)
	if err != nil {
		return err
	}
	defer conn.Close(context.Background())

	res := conn.ExecParams(ctx,
		"SELECT item, value, status FROM volvra.companion_status()",
		nil, nil, nil, nil).Read()
	if res.Err != nil {
		return res.Err
	}
	for _, row := range res.Rows {
		fmt.Printf("%-18s %-28s %s\n", string(row[0]), string(row[1]), string(row[2]))
	}
	_ = time.Now
	return nil
}
