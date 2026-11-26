// Package modules records the module versions the gosu build upgrades to. It is never
// compiled into the image: its imports keep both modules required, so go mod tidy and
// Renovate record the checksums of their sources in go.sum.
package modules

import (
	_ "github.com/moby/sys/user"
	_ "golang.org/x/sys/unix"
)
