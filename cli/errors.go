package main

import "errors"

// errorsAs exists so db.go reads without an errors import at every call site.
func errorsAs(err error, target any) bool { return errors.As(err, target) }
