package main

// Connection and query helpers.
//
// Every value the user supplies is sent as a bind parameter, never
// interpolated into SQL. The bash CLI had to quote literals by hand, and a
// hand-written quoting function guarding a tool that runs UPDATE and DELETE
// against production is not a risk worth carrying when the driver will do it
// properly.

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgtype"
)

type DB struct{ conn *pgx.Conn }

// Connect uses the DSN when given and the standard PG* environment variables
// otherwise, which is what psql does and therefore what people expect.
func Connect(ctx context.Context, dsn string) (*DB, error) {
	cfg, err := pgx.ParseConfig(dsn)
	if err != nil {
		return nil, fmt.Errorf("connection string: %w", err)
	}
	// The engine lives in the volvra schema and is always named explicitly, so
	// no search_path is set here: a CLI that silently changed it would give
	// different answers from a psql session against the same database.
	conn, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		return nil, err
	}
	return &DB{conn: conn}, nil
}

func (d *DB) Close(ctx context.Context) {
	if d.conn != nil {
		_ = d.conn.Close(ctx)
	}
}

// Query runs a query and renders it, returning the number of rows.
func (d *DB) Query(ctx context.Context, sql string, args ...any) (*Table, error) {
	rows, err := d.conn.Query(ctx, sql, args...)
	if err != nil {
		return nil, friendly(err)
	}
	defer rows.Close()

	t := &Table{}
	for _, fd := range rows.FieldDescriptions() {
		t.Cols = append(t.Cols, fd.Name)
	}
	for rows.Next() {
		vals, err := rows.Values()
		if err != nil {
			return nil, friendly(err)
		}
		cells := make([]string, len(vals))
		for i, v := range vals {
			cells[i] = render(v)
		}
		t.Add(cells...)
	}
	if err := rows.Err(); err != nil {
		return nil, friendly(err)
	}
	return t, nil
}

// One returns the first column of the first row, or "" when there is no row.
func (d *DB) One(ctx context.Context, sql string, args ...any) (string, error) {
	var v any
	err := d.conn.QueryRow(ctx, sql, args...).Scan(&v)
	if err == pgx.ErrNoRows {
		return "", nil
	}
	if err != nil {
		return "", friendly(err)
	}
	return render(v), nil
}

// Count is One for an integer, defaulting to zero rather than erroring, so a
// caller can treat "no answer" and "none" alike where that is the right
// reading.
func (d *DB) Count(ctx context.Context, sql string, args ...any) (int64, error) {
	var n int64
	if err := d.conn.QueryRow(ctx, sql, args...).Scan(&n); err != nil {
		if err == pgx.ErrNoRows {
			return 0, nil
		}
		return 0, friendly(err)
	}
	return n, nil
}

// render turns a driver value into what the user should see. NULL becomes the
// null mark, and a timestamp is printed to the second, because a microsecond
// is noise in a report a person reads.
func render(v any) string {
	switch x := v.(type) {
	case nil:
		return nullMark
	case time.Time:
		return x.Format("2006-01-02 15:04:05Z07:00")
	case []byte:
		return string(x)
	case string:
		return x
	case fmt.Stringer:
		return x.String()
	case pgtype.Interval:
		return interval(x)
	case bool:
		// t and f, as psql prints them: this output is read next to psql
		// output, and two spellings of the same boolean is a papercut.
		if x {
			return "t"
		}
		return "f"
	case map[string]any, []any:
		// jsonb arrives as a decoded map or slice. Printing it with %v gives
		// Go's own syntax -- a primary key rendered as map[id:3] is not
		// something anyone can paste back into a query.
		if b, err := json.Marshal(x); err == nil {
			return string(b)
		}
		return fmt.Sprintf("%v", x)
	default:
		return fmt.Sprintf("%v", x)
	}
}

// friendly turns the two errors people actually hit into sentences that say
// what to do, and leaves everything else exactly as the server phrased it --
// volvra's own messages are written to be read, and rewording them would lose
// the hint and the detail the engine attaches.
func friendly(err error) error {
	var pg *pgconn.PgError
	if !errorsAs(err, &pg) {
		return err
	}
	switch {
	case pg.Code == "42P01" && strings.Contains(pg.Message, "volvra."):
		return fmt.Errorf("volvra is not installed in this database: %s\n"+
			"Install it with:  psql -f sql/volvra.sql", pg.Message)
	case pg.Code == "3F000" && strings.Contains(pg.Message, "volvra"):
		return fmt.Errorf("no volvra schema in this database -- "+
			"is the connection pointing where you think?\n  %s", pg.Message)
	}
	// The engine prefixes its own messages with "volvra:", and so does this
	// program when it prints an error, so passing one through unchanged reads
	// as "volvra: volvra: ...".
	msg := strings.TrimPrefix(pg.Message, "volvra: ")
	if pg.Hint != "" {
		return fmt.Errorf("%s\nhint: %s", msg, pg.Hint)
	}
	return fmt.Errorf("%s", msg)
}

// interval prints an interval the way PostgreSQL does, because the driver
// hands it over as a struct and %v turns "23 hours" into {82800000000 0 0 true}
// -- which is the sort of detail that makes a tool feel unfinished.
func interval(iv pgtype.Interval) string {
	if !iv.Valid {
		return nullMark
	}
	var parts []string
	if y := iv.Months / 12; y != 0 {
		parts = append(parts, plural(int(y), "year"))
	}
	if m := iv.Months % 12; m != 0 {
		parts = append(parts, fmt.Sprintf("%d mons", m))
	}
	if iv.Days != 0 {
		parts = append(parts, plural(int(iv.Days), "day"))
	}

	us := iv.Microseconds
	neg := ""
	if us < 0 {
		neg, us = "-", -us
	}
	h := us / 3_600_000_000
	m := (us / 60_000_000) % 60
	sec := float64(us%60_000_000) / 1e6
	if h != 0 || m != 0 || sec != 0 || len(parts) == 0 {
		parts = append(parts, fmt.Sprintf("%s%02d:%02d:%05.2f", neg, h, m, sec))
	}
	return strings.Join(parts, " ")
}

func plural(n int, unit string) string {
	if n == 1 || n == -1 {
		return fmt.Sprintf("%d %s", n, unit)
	}
	return fmt.Sprintf("%d %ss", n, unit)
}
