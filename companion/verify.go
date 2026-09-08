package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

type Finding struct {
	Segment int
	Verdict string
	Detail  string
}

// VerifyArchive re-hashes every segment and re-walks the chain. It needs no
// database and no network: an archive whose integrity depends on the system
// that produced it is not a durable copy of anything.
func VerifyArchive(dir string) ([]Finding, *Manifest, error) {
	m, err := ReadManifest(dir)
	if err != nil {
		return nil, nil, err
	}

	var out []Finding
	prevChain := ""
	prevEnd := ""

	for _, seg := range m.Segments {
		path := filepath.Join(dir, seg.File)
		f, err := os.Open(path)
		if err != nil {
			out = append(out, Finding{seg.Seq, "MISSING", err.Error()})
			prevChain = seg.Chain
			continue
		}

		h := sha256.New()
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 0, 1<<20), 64<<20)
		var lines int64
		badJSON := 0
		for sc.Scan() {
			b := append(sc.Bytes(), '\n')
			h.Write(b)
			lines++
			var c Change
			if json.Unmarshal(sc.Bytes(), &c) != nil {
				badJSON++
			}
		}
		scanErr := sc.Err()
		f.Close()
		if scanErr != nil {
			out = append(out, Finding{seg.Seq, "UNREADABLE", scanErr.Error()})
			prevChain = seg.Chain
			continue
		}

		sum := hex.EncodeToString(h.Sum(nil))
		chain := sha256.Sum256([]byte(prevChain + "|" + seg.SHA256))

		switch {
		case sum != seg.SHA256:
			out = append(out, Finding{seg.Seq, "TAMPERED",
				fmt.Sprintf("content hash %s, manifest says %s", sum[:16], seg.SHA256[:16])})
		case seg.Prev != prevChain:
			out = append(out, Finding{seg.Seq, "CHAIN BROKEN",
				"this segment does not follow the previous one -- one was removed, " +
					"reordered or inserted"})
		case hex.EncodeToString(chain[:]) != seg.Chain:
			out = append(out, Finding{seg.Seq, "MANIFEST FORGED",
				"the manifest entry itself has been altered"})
		case lines != seg.Changes:
			out = append(out, Finding{seg.Seq, "TRUNCATED",
				fmt.Sprintf("%d lines present, %d recorded", lines, seg.Changes)})
		case badJSON > 0:
			out = append(out, Finding{seg.Seq, "CORRUPT",
				fmt.Sprintf("%d line(s) are not valid change records", badJSON)})
		}

		// A break in LSN continuity between segments is only alarming if no gap
		// was recorded for it -- the companion writes one when it skips.
		if prevEnd != "" && seg.StartLSN != "" && !gapRecorded(dir, m, seg.Seq) &&
			seg.StartLSN < prevEnd {
			out = append(out, Finding{seg.Seq, "OUT OF ORDER",
				fmt.Sprintf("starts at %s, previous ended at %s", seg.StartLSN, prevEnd)})
		}

		prevChain = seg.Chain
		prevEnd = seg.EndLSN
	}
	return out, m, nil
}

func gapRecorded(dir string, m *Manifest, seq int) bool {
	for _, s := range m.Segments {
		if s.Seq != seq && s.Seq != seq-1 {
			continue
		}
		f, err := os.Open(filepath.Join(dir, s.File))
		if err != nil {
			continue
		}
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 0, 1<<20), 64<<20)
		for sc.Scan() {
			var c Change
			if json.Unmarshal(sc.Bytes(), &c) == nil && c.Gap {
				f.Close()
				return true
			}
		}
		f.Close()
	}
	return false
}
