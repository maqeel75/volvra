package main

// The selector: one way of naming a set of changes, shared by preview and
// undo.
//
// Every field is sent as a bind parameter and NULL means "not specified",
// which is exactly what the SQL defaults are. So the call is always the same
// shape and only the arguments differ -- no SQL is assembled from user input.

import (
	"errors"
	"fmt"
	"strconv"
)

type Selector struct {
	Table     string
	Txid      string
	Since     string
	Until     string
	Actor     string
	User      string
	Where     string
	Mark      string
	MaxRows   string
	SkipConfl bool
}

func (s *Selector) empty() bool {
	return s.Table == "" && s.Txid == "" && s.Since == "" && s.Until == "" &&
		s.Actor == "" && s.User == "" && s.Where == "" && s.Mark == ""
}

// parse reads the selector flags. Unknown flags are refused rather than
// ignored: a mistyped --tabel that silently widened the selection to every
// covered table is the worst possible failure for this particular command.
func (s *Selector) parse(args []string) error {
	need := func(i int, flag string) (string, error) {
		if i+1 >= len(args) {
			return "", fmt.Errorf("%s needs a value", flag)
		}
		return args[i+1], nil
	}
	for i := 0; i < len(args); i++ {
		var err error
		switch a := args[i]; a {
		case "--table":
			s.Table, err = need(i, a)
			i++
		case "--txid":
			s.Txid, err = need(i, a)
			i++
		case "--since":
			s.Since, err = need(i, a)
			i++
		case "--until":
			s.Until, err = need(i, a)
			i++
		case "--actor":
			s.Actor, err = need(i, a)
			i++
		case "--user":
			s.User, err = need(i, a)
			i++
		case "--where":
			s.Where, err = need(i, a)
			i++
		case "--to":
			s.Mark, err = need(i, a)
			i++
		case "--max-rows":
			s.MaxRows, err = need(i, a)
			i++
		case "--skip-conflicts":
			s.SkipConfl = true
		default:
			return fmt.Errorf("unknown selector option: %s", a)
		}
		if err != nil {
			return err
		}
	}

	if s.empty() {
		return errors.New("a selector is required -- name a table, a txid, " +
			"a time, an actor or a predicate")
	}
	// --to resolves to the mark's moment, which is a from_ts, so the two
	// cannot both be given. The bash CLI passed from_ts twice here and let
	// Postgres reject it with a message about named arguments.
	if s.Mark != "" && s.Since != "" {
		return errors.New("--to and --since both set the start of the window; " +
			"use one. --to NAME means \"since the moment NAME was taken\"")
	}
	if s.Txid != "" {
		if _, err := strconv.ParseInt(s.Txid, 10, 64); err != nil {
			return fmt.Errorf("--txid must be a number, got %q", s.Txid)
		}
	}
	if s.MaxRows != "" {
		if _, err := strconv.Atoi(s.MaxRows); err != nil {
			return fmt.Errorf("--max-rows must be a number, got %q", s.MaxRows)
		}
	}
	return nil
}

// nullable turns an unset string into a real SQL NULL.
func nullable(s string) any {
	if s == "" {
		return nil
	}
	return s
}

// args returns the eight selector bind parameters, in the order the SQL below
// uses them. Relative times like "10 min ago" stay strings and are cast by
// Postgres, so the clock that resolves them is the server's -- which is the
// same clock that wrote the history.
func (s *Selector) args() []any {
	return []any{
		nullable(s.Table), // $1 target
		nullable(s.Since), // $2 from_ts
		nullable(s.Until), // $3 to_ts
		nullable(s.Txid),  // $4 txid
		nullable(s.Actor), // $5 actor
		nullable(s.User),  // $6 db_user
		nullable(s.Where), // $7 predicate
		nullable(s.Mark),  // $8 mark name
	}
}

// when builds the expression that turns one text parameter into a timestamptz.
//
// It exists because "10 min ago" is not a timestamptz. PostgreSQL accepts
// 'yesterday', 'today' and 'now' as literals but not '10 min ago', so the
// documented examples -- `--since '10 min ago'`, `--since '1 hour ago'` --
// never worked in the shell CLI these commands come from: every one of them
// failed with "invalid input syntax for type timestamp with time zone".
//
// A trailing "ago" is therefore read as an interval before now. The subtraction
// happens on the server, so the clock that resolves it is the clock that wrote
// the history -- which is the only clock whose answer is meaningful here.
//
// ph is a placeholder this package writes ("$2"), never user input; the value
// it stands for is bound.
func when(ph string) string {
	// Every use is cast to text: the first mention of the parameter is inside
	// an IS NULL test, from which PostgreSQL cannot infer a type, and it
	// answers "could not determine data type of parameter" instead.
	p := ph + `::text`
	return `CASE
	          WHEN ` + p + ` IS NULL THEN NULL
	          WHEN lower(btrim(` + p + `)) LIKE '%ago'
	            THEN now() - btrim(regexp_replace(` + p + `,
	                                              '(?i)\s*ago\s*$', ''))::interval
	          ELSE ` + p + `::timestamptz
	        END`
}

// call is the argument list for volvra.preview_undo and volvra.undo.
//
// from_ts is either the given time or the mark's moment; COALESCE picks
// whichever was supplied, and parse() has already refused both at once.
var call = `
  target    => $1::regclass,
  from_ts   => coalesce(` + when("$2") + `,
                        (SELECT at FROM volvra.restore_point WHERE name = $8)),
  to_ts     => ` + when("$3") + `,
  txid      => $4::bigint,
  actor     => $5::text,
  db_user   => $6::text,
  predicate => $7::text`
