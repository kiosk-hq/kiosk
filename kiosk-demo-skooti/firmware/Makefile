# Makefile — skooti firmware Ed25519 host crypto test (offline Ed25519)
#
# Targets:
#   make test        — compile + run C host test + Ruby crosscheck
#   make crosscheck  — Ruby Ed25519 sign → C verify (live key proof)
#   make test-asan   — host test under AddressSanitizer (ASAN_CC, default clang)
#   make portability — the same sources through every C compiler on this machine
#   make build       — compile only (no run)
#   make clean       — remove build artefacts
#
# The .ino is NOT compiled here (requires the ESP32-C3 Arduino toolchain).
# See README.md for flashing instructions.

CC      ?= cc

# ONE FLAG LIST, SHARED BY EVERY TARGET — because two lists is how K-1609
# happened. `test` and `test-asan` each carried their own `-std=c99 …` string,
# so the declaration this build needs could be absent from one and present in
# neither, and nothing lined them up.
#
# WHY THE FEATURE-TEST MACRO IS LOAD-BEARING RATHER THAN DECORATION: `strnlen`
# is POSIX.1-2008, and POSIX says a program that wants it must ask for that
# level before including any header. glibc obeys literally — `<string.h>`
# declares `strnlen` only under `_POSIX_C_SOURCE >= 200809L` or `_GNU_SOURCE`,
# and `-std=c99` defines `__STRICT_ANSI__`, under which glibc's `features.h`
# defines neither. Apple's libc gates the SAME function on `__DARWIN_C_LEVEL >=
# 200809L` but leaves that level at `__DARWIN_C_FULL` whatever `-std=` says, so
# an omitted macro is invisible on macOS and fatal on Linux: the first CI run
# this firmware ever had failed with «call to undeclared function 'strnlen'» on
# four lines that had compiled clean here for months.
#
# AND ASKING EXPLICITLY IS WHAT MAKES THIS MACHINE A PROXY FOR THAT RUNNER.
# `-D_POSIX_C_SOURCE=200809L` does not only ADD the POSIX.1-2008 names on
# glibc, it pushes macOS DOWN from `__DARWIN_C_FULL` to exactly that level — so
# a BSD-only extension now fails to compile HERE instead of on a runner.
# MEASURED: a one-line `strlcpy` call compiles clean under plain `-std=c99` on
# this machine and fails under `-std=c99 -D_POSIX_C_SOURCE=200809L`.
#
# AND `-Werror=implicit-function-declaration` IS THE OTHER HALF, because the
# two toolchains disagree about severity, not just about the declaration:
# clang 16+ makes an implicit declaration an ERROR, gcc still makes it a
# WARNING. Under `make test` on Linux the same missing declaration therefore
# BUILT — a call typed `int (*)()` where the function returns `size_t`, which
# is undefined behaviour in a verifier a physical lock runs. The flag makes the
# two steps agree, and it is scoped to this one diagnostic rather than a blanket
# `-Werror` so that a future compiler's unrelated new warning cannot redden a
# security gate.
BASE_CFLAGS := -std=c99 -D_POSIX_C_SOURCE=200809L \
               -Wall -Wextra -Wpedantic \
               -Werror=implicit-function-declaration \
               -Ied25519

CFLAGS  := $(BASE_CFLAGS) -O2
TARGET  := host_test

# Ed25519 vendored sources (orlp/ed25519, zlib license)
ED25519_SRCS := \
    ed25519/verify.c \
    ed25519/sha512.c \
    ed25519/ge.c \
    ed25519/fe.c \
    ed25519/sc.c

# Our sources
SRCS := verify.c jti_store.c host_test.c $(ED25519_SRCS)

HDRS := verify.h \
    jti_store.h \
    ed25519/ed25519.h \
    ed25519/sha512.h \
    ed25519/ge.h \
    ed25519/fe.h \
    ed25519/sc.h \
    ed25519/fixedint.h \
    ed25519/precomp_data.h

.PHONY: all build test crosscheck test-asan portability clean

all: test

build: $(TARGET)

$(TARGET): $(SRCS) $(HDRS)
	$(CC) $(CFLAGS) -o $@ $(SRCS)

# --------------------------------------------------------------------------
# make test: compile, run C host test, then run Ruby crosscheck
# --------------------------------------------------------------------------
test: build
	@echo "--- C host test ---"
	@./$(TARGET)
	@echo ""
	@$(MAKE) --no-print-directory crosscheck

# --------------------------------------------------------------------------
# make crosscheck: Ruby OpenSSL Ed25519 sign → C verify MATCH
#
# READS the dev private key from ../config/dev_unlock_key.pem — the one file
# the server, the KAT and the flow drivers all read. Do NOT inline a COPY of
# that PEM here: that would be a second place a burned key is published and a
# silent drift hazard, because regenerating the key would leave this target
# signing with the old one. Signs a fresh message and passes the wire
# token to the C verifier, proving C verifies a LIVE server-issued token, not
# just the static vector. Relative path: make runs recipes in this directory.
#
# Then crosscheck_grammar.rb runs the other half of the same question — what
# the readers REFUSE — over the whole token grammar and through ALL THREE
# readers this token has: the C verifier via the helper below, the shipped
# RentalTokenIssuer.verify, and script/lock_sim.rb. Its vectors live in
# token_vectors.rb, whose header states the grammar and why every vector
# carries a live signature.
#
# And check_grammar_coverage.rb closes the loop the other way: the grammar is
# stated in prose in ../RENTAL_TOKEN.md and pinned in vectors here, and that
# gate fails when the page names a rule no axis exercises, or an axis exists
# that no rule names. A rule nobody wrote a vector for reads exactly like a
# rule everybody implements, which is how the signature-encoding hole stayed
# open; its header states what it cannot see.
# --------------------------------------------------------------------------
crosscheck: $(TARGET)_crosscheck
	@echo "--- Ruby ↔ C crosscheck ---"
	@CROSSCHECK_RESULT=$$(ruby -r openssl -r base64 -e ' \
	  key = OpenSSL::PKey.read(File.read("../config/dev_unlock_key.pem")); \
	  msg = "kiosk-rental-v1|SK-001|resv-live|1750001000|1750001900|deadbeef00112233445566778899aabb"; \
	  sig = key.sign(nil, msg); \
	  sig_b64 = Base64.urlsafe_encode64(sig, padding: false); \
	  puts "#{msg}.#{sig_b64}" \
	') && \
	echo "  Ruby-signed token: $$CROSSCHECK_RESULT" && \
	./$(TARGET)_crosscheck "$$CROSSCHECK_RESULT"
	@ruby crosscheck_grammar.rb ./$(TARGET)_crosscheck
	@ruby check_grammar_coverage.rb

# The crosscheck helper binary verifies a single token passed as argv[1]
# using now=1750001800 (inside the live-window), SCOOTER_CODE="SK-001".
# Exit 0 means the C verifier accepted it, 1 means it refused — which is how
# crosscheck_grammar.rb reads the C answer for the vectors it expects refused.
# Built separately so the main host_test is self-contained.
$(TARGET)_crosscheck: crosscheck_main.c verify.c $(ED25519_SRCS) $(HDRS)
	$(CC) $(CFLAGS) -o $@ crosscheck_main.c verify.c $(ED25519_SRCS)

# --------------------------------------------------------------------------
# make test-asan: compile + run host_test under AddressSanitizer
#
# Proves the oversized-sig regression case returns 0 with NO overflow report.
# Needs a compiler with ASan support (macOS: ships with the Xcode Command Line
# Tools; Linux: apt install clang).  If none is available, the bounded decoder
# (dst_cap guard) is the real fix regardless — use `make test` instead.
#
# `ASAN_CC` is a variable rather than a hard-coded `clang` for the reason
# K-1609 records: this target used to name `clang` where every other target
# honours `CC`, so one job was building the same sources with two compilers
# without saying so, and the two disagreed about whether a missing declaration
# was fatal.  Whoever runs this picks the compiler ONCE, here or in the
# environment, and `make portability` below runs every compiler on the machine.
# --------------------------------------------------------------------------
ASAN_CC     ?= clang
ASAN_TARGET := $(TARGET)_asan
ASAN_FLAGS  := $(BASE_CFLAGS) -O1 \
               -fsanitize=address -fno-omit-frame-pointer

# SRCS already includes jti_store.c (required by host_test.c)
$(ASAN_TARGET): $(SRCS) $(HDRS)
	$(ASAN_CC) $(ASAN_FLAGS) -o $@ $(SRCS)

test-asan: $(ASAN_TARGET)
	@echo "--- C host test (AddressSanitizer) ---"
	@./$(ASAN_TARGET)
	@echo ""
	@echo "ASan: no overflow detected (all cases above passed cleanly)"

# --------------------------------------------------------------------------
# make portability: these sources through EVERY C compiler on this machine
#
# K-1609 shipped because this firmware had only ever been compiled by one
# compiler on one libc, and the CI job that first ran it on a second of each
# failed to build at all.  A local target cannot conjure a second libc — but it
# can do the two things that ARE local, and between them they cover the defect:
#
#   1. every distinct compiler driver installed here, not just `$(CC)`.  On a
#      Linux runner that is gcc AND clang, which is exactly the pair whose
#      disagreement about implicit declarations hid the fault for one step and
#      exposed it in the next.
#   2. the POSIX.1-2008 feature level `BASE_CFLAGS` asks for, which on macOS is
#      STRICTER than the default — so a name this code takes from a BSD or GNU
#      extension rather than from POSIX fails here, where it would otherwise
#      have waited for a runner to say so.
#
# `-fsyntax-only`, so it is seconds rather than a build; the failure this
# catches is a declaration, and a declaration is a front-end question.  Exits
# non-zero on the first compiler that refuses the sources, naming it.
#
# IT DEDUPES ON THE RESOLVED PATH *AND* ON THE VERSION STRING, because each key
# alone overcounts on one of the two platforms and the printed count is a claim.
# MEASURED, first run of this target on ubuntu-latest: version-string alone said
# «3 distinct compiler(s)» for gcc, clang and cc — where `cc` is the SAME binary
# as gcc through the alternatives symlink and only prints a different argv[0] in
# its first line.  Path alone is no better: on macOS `/usr/bin/cc` and
# `/usr/bin/clang` are two separate files that are one compiler, and neither is
# a symlink for `readlink -f` to resolve.
# --------------------------------------------------------------------------
portability:
	@seen=''; paths=''; n=0; \
	for c in $(CC) $(ASAN_CC) cc clang gcc; do \
	  p=`command -v "$$c" 2>/dev/null` || { echo "  skip $$c — not installed"; continue; }; \
	  rp=`readlink -f "$$p" 2>/dev/null` || rp="$$p"; \
	  case ":$$paths:" in *":$$rp:"*) continue;; esac; \
	  id=`"$$c" --version 2>&1 | head -1 | tr -cd 'A-Za-z0-9.'`; \
	  case ":$$seen:" in *":$$id:"*) continue;; esac; \
	  paths="$$paths:$$rp"; seen="$$seen:$$id"; n=`expr $$n + 1`; \
	  echo "--- $$c: `"$$c" --version 2>&1 | head -1`"; \
	  "$$c" $(BASE_CFLAGS) -fsyntax-only $(SRCS) crosscheck_main.c || exit 1; \
	done; \
	if [ "$$n" -eq 0 ]; then echo "portability: NO C compiler found at all" >&2; exit 1; fi; \
	echo "portability: $$n distinct compiler(s) on this machine accept these sources (-fsyntax-only) at _POSIX_C_SOURCE=200809L; a second libc is not reachable from here and is CI's job"

clean:
	rm -f $(TARGET) $(TARGET)_crosscheck $(ASAN_TARGET) *.o
