# Build the volvra companion -- the durable tier.
#
#   make               build for this machine
#   make install       into /usr/local/bin (needs write access there)
#   make linux         cross-build for a linux container, this architecture
#   make release       the two binaries we ship, plus checksums
#   make test          vet and unit tests
#
# ---------------------------------------------------------------------
# Why CGO_ENABLED=0 everywhere
#
# The companion runs on the customer's own hosts, wherever they choose to
# put it, so it has the same portability requirement as the CLI: we ship
# two binaries, one per architecture, and expect them to run on
# EL9, EL10, Debian bullseye through trixie, and Ubuntu jammy through
# resolute. That only holds if the binary has no libc dependency at all.
#
# Go enables cgo by default whenever a C toolchain is present, and the
# net and os/user packages then use their cgo implementations, which
# links libc dynamically. A binary built that way on trixie needs that
# machine's glibc: run it on bullseye, jammy or EL9 and it dies with
# "GLIBC_2.xx not found" before main() is reached. Nothing in the build
# warns you, because on the machine that built it the binary is fine.
#
# CGO_ENABLED=0 makes the binary statically linked and libc-independent,
# so one binary per architecture covers every distribution above. The
# cost is that hostname and username lookups use Go's own resolvers
# rather than NSS, which means /etc/hosts, /etc/resolv.conf and
# /etc/passwd are consulted but LDAP and SSSD are not. For a tool that
# connects to a database by hostname that is the right trade.
# ---------------------------------------------------------------------
export CGO_ENABLED = 0

# The compatibility floor, set explicitly rather than left to the
# toolchain's default, so a future Go release cannot quietly raise it.
# GOAMD64=v1 is baseline x86-64: no SSE4, no AVX, no POPCNT required.
# GOARM64=v8.0 is the ARMv8.0-A baseline, which is what EL9 aarch64
# targets.
export GOAMD64 = v1
export GOARM64 = v8.0

# VERSION comes from git so `volvra-companion` version output says something useful; a
# tree with no tags reports the commit, and one with no git at all
# reports "dev".
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)

# -s -w drop the symbol table and DWARF: the companion does not ship a debugger,
# and it roughly halves the file.
# -trimpath removes build-machine paths, so two people building the same
# commit get the same bytes.
LDFLAGS = -s -w -X main.version=$(VERSION)
GOFLAGS = -trimpath
PREFIX ?= /usr/local
DIST   ?= dist

.PHONY: all install linux release clean test

all: volvra-companion

volvra-companion: $(wildcard *.go) go.mod
	go build $(GOFLAGS) -ldflags "$(LDFLAGS)" -o volvra-companion .

install: volvra-companion
	install -m 0755 volvra-companion $(PREFIX)/bin/volvra-companion

# GOARCH defaults to this machine's, which is what you want for Docker
# Desktop on Apple silicon and for an x86 CI runner alike.
linux:
	GOOS=linux go build $(GOFLAGS) -ldflags "$(LDFLAGS)" -o volvra-companion-linux .

# The two binaries a release publishes. Checksums are part of the
# release, not an afterthought: volvra installs as a file rather than a
# signed package, so the checksum is how anyone verifies what they got.
release:
	mkdir -p $(DIST)
	GOOS=linux GOARCH=amd64 go build $(GOFLAGS) -ldflags "$(LDFLAGS)" \
	  -o $(DIST)/volvra-companion-linux-amd64 .
	GOOS=linux GOARCH=arm64 go build $(GOFLAGS) -ldflags "$(LDFLAGS)" \
	  -o $(DIST)/volvra-companion-linux-arm64 .
	cd $(DIST) && shasum -a 256 volvra-companion-linux-amd64 volvra-companion-linux-arm64 \
	  > volvra-companion-$(VERSION)-checksums.txt
	@echo
	@ls -l $(DIST)
	@echo
	@cat $(DIST)/volvra-companion-$(VERSION)-checksums.txt

test:
	go vet ./...
	go test ./...

clean:
	rm -f volvra-companion volvra-companion-linux
	rm -rf $(DIST)
