package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"hash"
	"os"
	"path/filepath"
	"sort"
	"time"
)

// The archive is the durability promise, so it has to be readable without
// Postgres, without this binary, and without any index: newline-delimited JSON
// in numbered segments, described by a manifest.
//
// Segments are chained by SHA-256 the same way volvra.seal() chains the
// in-database history. Losing or editing a segment is therefore detectable,
// and a gap that the companion *recorded* is distinguishable from one it did
// not -- which is the same principle retention and erasure follow.

const archiveFormat = 1

type Change struct {
	LSN      string          `json:"lsn"`
	XID      uint32          `json:"xid,omitempty"`
	CommitTS time.Time       `json:"commit_ts"`
	Table    string          `json:"table,omitempty"`
	Op       string          `json:"op,omitempty"` // I/U/D/T
	PK       json.RawMessage `json:"pk,omitempty"`
	Old      json.RawMessage `json:"old,omitempty"`
	New      json.RawMessage `json:"new,omitempty"`

	// Gap records carry no row data. They exist so that missing history is
	// explained rather than silent.
	Gap     bool   `json:"gap,omitempty"`
	FromLSN string `json:"from_lsn,omitempty"`
	ToLSN   string `json:"to_lsn,omitempty"`
	Reason  string `json:"reason,omitempty"`
}

type Segment struct {
	Seq      int    `json:"seq"`
	File     string `json:"file"`
	StartLSN string `json:"start_lsn"`
	EndLSN   string `json:"end_lsn"`
	Changes  int64  `json:"changes"`
	Bytes    int64  `json:"bytes"`
	SHA256   string `json:"sha256"`
	Prev     string `json:"prev,omitempty"` // previous segment's chain
	Chain    string `json:"chain"`          // sha256(prev || sha256)
	SealedAt string `json:"sealed_at"`
}

type Manifest struct {
	Archive     string    `json:"archive"`
	Format      int       `json:"format"`
	Slot        string    `json:"slot"`
	Publication string    `json:"publication,omitempty"`
	CreatedAt   string    `json:"created_at"`
	Segments    []Segment `json:"segments"`
}

type Archive struct {
	dir      string
	man      Manifest
	cur      *os.File
	curSeq   int
	curStart string
	curEnd   string
	curCount int64
	curBytes int64
	hasher   hash.Hash
	maxBytes int64
}

func OpenArchive(dir, slot, publication string, maxBytes int64) (*Archive, error) {
	if err := os.MkdirAll(dir, 0o750); err != nil {
		return nil, err
	}
	a := &Archive{dir: dir, maxBytes: maxBytes}

	mp := filepath.Join(dir, "manifest.json")
	b, err := os.ReadFile(mp)
	switch {
	case err == nil:
		if err := json.Unmarshal(b, &a.man); err != nil {
			return nil, fmt.Errorf("manifest is unreadable, refusing to append: %w", err)
		}
		if a.man.Format != archiveFormat {
			return nil, fmt.Errorf("archive format %d, this build writes %d",
				a.man.Format, archiveFormat)
		}
		if a.man.Slot != slot {
			return nil, fmt.Errorf("archive belongs to slot %q, not %q -- refusing to mix",
				a.man.Slot, slot)
		}
	case os.IsNotExist(err):
		a.man = Manifest{
			Archive:     "volvra",
			Format:      archiveFormat,
			Slot:        slot,
			Publication: publication,
			CreatedAt:   time.Now().UTC().Format(time.RFC3339Nano),
		}
		if err := a.writeManifest(); err != nil {
			return nil, err
		}
	default:
		return nil, err
	}
	return a, nil
}

// ResumeLSN is the last LSN durably in the archive, and therefore the only
// point it is safe to tell Postgres it may discard WAL up to.
func (a *Archive) ResumeLSN() string {
	if n := len(a.man.Segments); n > 0 {
		return a.man.Segments[n-1].EndLSN
	}
	return ""
}

func (a *Archive) writeManifest() error {
	b, err := json.MarshalIndent(a.man, "", "  ")
	if err != nil {
		return err
	}
	tmp := filepath.Join(a.dir, ".manifest.json.tmp")
	if err := os.WriteFile(tmp, append(b, '\n'), 0o640); err != nil {
		return err
	}
	// Rename is the atomic step: a torn manifest would make the whole archive
	// unreadable, which is worse than losing the last segment.
	if err := os.Rename(tmp, filepath.Join(a.dir, "manifest.json")); err != nil {
		return err
	}
	d, err := os.Open(a.dir)
	if err == nil {
		_ = d.Sync()
		_ = d.Close()
	}
	return nil
}

func (a *Archive) open() error {
	a.curSeq = len(a.man.Segments) + 1
	name := fmt.Sprintf("%010d.ndjson", a.curSeq)
	f, err := os.OpenFile(filepath.Join(a.dir, name),
		os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o640)
	if err != nil {
		return err
	}
	a.cur, a.curCount, a.curBytes = f, 0, 0
	a.curStart, a.curEnd = "", ""
	a.hasher = sha256.New()
	return nil
}

func (a *Archive) Append(c Change) error {
	if a.cur == nil {
		if err := a.open(); err != nil {
			return err
		}
	}
	b, err := json.Marshal(c)
	if err != nil {
		return err
	}
	b = append(b, '\n')
	if _, err := a.cur.Write(b); err != nil {
		return err
	}
	a.hasher.Write(b)
	a.curBytes += int64(len(b))
	a.curCount++
	if a.curStart == "" {
		a.curStart = c.LSN
	}
	a.curEnd = c.LSN

	if a.curBytes >= a.maxBytes {
		return a.Rotate()
	}
	return nil
}

// Rotate closes the current segment and only then records it in the manifest.
// Nothing is acknowledged to Postgres before this returns.
func (a *Archive) Rotate() error {
	if a.cur == nil || a.curCount == 0 {
		return nil
	}
	if err := a.cur.Sync(); err != nil {
		return err
	}
	name := a.cur.Name()
	if err := a.cur.Close(); err != nil {
		return err
	}
	a.cur = nil

	sum := hex.EncodeToString(a.hasher.Sum(nil))
	prev := ""
	if n := len(a.man.Segments); n > 0 {
		prev = a.man.Segments[n-1].Chain
	}
	chain := sha256.Sum256([]byte(prev + "|" + sum))

	a.man.Segments = append(a.man.Segments, Segment{
		Seq:      a.curSeq,
		File:     filepath.Base(name),
		StartLSN: a.curStart,
		EndLSN:   a.curEnd,
		Changes:  a.curCount,
		Bytes:    a.curBytes,
		SHA256:   sum,
		Prev:     prev,
		Chain:    hex.EncodeToString(chain[:]),
		SealedAt: time.Now().UTC().Format(time.RFC3339Nano),
	})
	return a.writeManifest()
}

func (a *Archive) Stats() (segments int, changes int64) {
	for _, s := range a.man.Segments {
		changes += s.Changes
	}
	return len(a.man.Segments), changes
}

func (a *Archive) Close() error { return a.Rotate() }

// ReadManifest is used by verify and restore, which must work with no database
// and no running companion.
func ReadManifest(dir string) (*Manifest, error) {
	b, err := os.ReadFile(filepath.Join(dir, "manifest.json"))
	if err != nil {
		return nil, err
	}
	var m Manifest
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, err
	}
	sort.Slice(m.Segments, func(i, j int) bool { return m.Segments[i].Seq < m.Segments[j].Seq })
	return &m, nil
}
