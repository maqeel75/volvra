package main

// Table rendering.
//
// The bash CLI borrowed psql's formatting, which is why it needed psql on the
// PATH. Rendering here is what makes the binary self-contained, and it is the
// only reason this file exists.

import (
	"fmt"
	"io"
	"strings"
	"unicode/utf8"
)

// nullMark is what an absent value looks like. Printing nothing at all makes a
// NULL indistinguishable from an empty string, and for a tool whose subject is
// "what was this value before" that distinction is the whole point.
const nullMark = "∅"

type Table struct {
	Cols []string
	Rows [][]string
}

func (t *Table) Add(cells ...string) { t.Rows = append(t.Rows, cells) }

// Write renders the table in psql's border=2 style, so output people have
// learned to read from psql still reads the same.
func (t *Table) Write(w io.Writer) {
	if len(t.Cols) == 0 {
		return
	}

	width := make([]int, len(t.Cols))
	for i, c := range t.Cols {
		width[i] = cellWidth(c)
	}
	for _, r := range t.Rows {
		for i := range t.Cols {
			if i < len(r) && cellWidth(r[i]) > width[i] {
				width[i] = cellWidth(r[i])
			}
		}
	}

	rule := func(l, mid, r string) {
		var b strings.Builder
		b.WriteString(l)
		for i, wd := range width {
			if i > 0 {
				b.WriteString(mid)
			}
			b.WriteString(strings.Repeat("─", wd+2))
		}
		b.WriteString(r)
		fmt.Fprintln(w, b.String())
	}

	line := func(cells []string, centre bool) {
		var b strings.Builder
		b.WriteString("│")
		for i, wd := range width {
			cell := ""
			if i < len(cells) {
				cell = cells[i]
			}
			pad := wd - cellWidth(cell)
			switch {
			case centre:
				left := pad / 2
				b.WriteString(" " + strings.Repeat(" ", left) + cell +
					strings.Repeat(" ", pad-left) + " ")
			default:
				b.WriteString(" " + cell + strings.Repeat(" ", pad) + " ")
			}
			_ = i
			b.WriteString("│")
		}
		fmt.Fprintln(w, b.String())
	}

	rule("┌", "┬", "┐")
	line(t.Cols, true)
	rule("├", "┼", "┤")
	for _, r := range t.Rows {
		line(r, false)
	}
	rule("└", "┴", "┘")

	switch len(t.Rows) {
	case 0:
		fmt.Fprintln(w, "(0 rows)")
	case 1:
		fmt.Fprintln(w, "(1 row)")
	default:
		fmt.Fprintf(w, "(%d rows)\n", len(t.Rows))
	}
}

// cellWidth counts runes rather than bytes, so a non-ASCII identifier or value
// does not skew the column it sits in.
func cellWidth(s string) int { return utf8.RuneCountInString(s) }
