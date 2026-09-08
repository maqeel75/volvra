package main

// preview and undo: the two commands that matter, and the only ones that ask
// before acting.

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"strings"

	"golang.org/x/term"
)

func cmdPreview(ctx context.Context, db *DB, args []string) (int, error) {
	var s Selector
	if err := s.parse(args); err != nil {
		return exitError, err
	}
	if _, _, err := showPlan(ctx, db, &s); err != nil {
		return exitError, err
	}
	return exitOK, nil
}

// showPlan prints the compensating SQL and returns how many changes it covers
// and how many of their rows have moved on since capture.
func showPlan(ctx context.Context, db *DB, s *Selector) (rows, conflicts int64, err error) {
	t, err := db.Query(ctx, `
		SELECT seq, table_name AS "table", op, inverse_op AS inverse,
		       pk, conflict, left(stmt, 70) || '…' AS "compensating sql"
		FROM volvra.preview_undo(`+call+`)`, s.args()...)
	if err != nil {
		return 0, 0, err
	}
	t.Write(os.Stdout)

	rows = int64(len(t.Rows))
	// Counting from the rendered plan rather than asking again keeps the number
	// and the table consistent: a second call could see a different database.
	for _, r := range t.Rows {
		for i, c := range t.Cols {
			if c == "conflict" && i < len(r) && r[i] == "t" {
				conflicts++
			}
		}
	}
	return rows, conflicts, nil
}

func cmdUndo(ctx context.Context, db *DB, args []string, yes bool) (int, error) {
	var s Selector
	if err := s.parse(args); err != nil {
		return exitError, err
	}

	rows, conflicts, err := showPlan(ctx, db, &s)
	if err != nil {
		return exitError, err
	}
	if rows == 0 {
		fmt.Println("\nNothing to undo for that selection.")
		return exitOK, nil
	}

	fmt.Printf("\n%d change(s) will be reverted", rows)
	if conflicts > 0 {
		fmt.Printf(", and %d row(s) have changed since they were captured", conflicts)
		if s.SkipConfl {
			fmt.Print(" -- those will be left alone")
		} else {
			fmt.Print(".\nUndo will refuse rather than overwrite them; pass " +
				"--skip-conflicts to\nrevert the rest and leave those alone")
		}
	}
	fmt.Println(".")

	ok, err := confirm("Apply this undo?", yes)
	if err != nil {
		return exitError, err
	}
	if !ok {
		fmt.Println("Nothing was changed.")
		return exitError, nil
	}

	sql := `SELECT seq, table_name AS "table", inverse_op AS applied, pk, status
	        FROM volvra.undo(` + call + `,
	          confirm => true, skip_conflicts => $9::boolean`
	a := append(s.args(), s.SkipConfl)
	if s.MaxRows != "" {
		sql += `, max_rows => $10::integer`
		a = append(a, s.MaxRows)
	}
	sql += `)`

	t, err := db.Query(ctx, sql, a...)
	if err != nil {
		return exitError, err
	}
	t.Write(os.Stdout)
	return exitOK, nil
}

// confirm asks once. Without a terminal it refuses rather than assuming yes,
// because the commands that call it are the ones that change data: a cron job
// that inherited an undo by accident must stop, not proceed.
func confirm(prompt string, yes bool) (bool, error) {
	if yes {
		return true, nil
	}
	if !term.IsTerminal(int(os.Stdin.Fd())) {
		return false, errors.New(
			"refusing to apply without a terminal to confirm on " +
				"(pass --yes deliberately)")
	}
	fmt.Fprintf(os.Stderr, "%s [y/N] ", prompt)
	line, err := bufio.NewReader(os.Stdin).ReadString('\n')
	if err != nil && line == "" {
		return false, nil
	}
	switch strings.TrimSpace(line) {
	case "y", "Y":
		return true, nil
	}
	return false, nil
}
