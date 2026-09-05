# Makefile — skooti firmware Ed25519 host crypto test (offline Ed25519)
#
# Targets:
#   make test        — compile + run C host test + Ruby crosscheck
#   make crosscheck  — Ruby Ed25519 sign → C verify (live key proof)
#   make build       — compile only (no run)
#   make clean       — remove build artefacts
#
# The .ino is NOT compiled here (requires the ESP32-C3 Arduino toolchain).
# See README.md for flashing instructions.

CC      ?= cc
CFLAGS  := -std=c99 -Wall -Wextra -Wpedantic -O2 -Ied25519
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

.PHONY: all build test crosscheck clean

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

# The crosscheck helper binary verifies a single token passed as argv[1]
# using now=1750001800 (inside the live-window), SCOOTER_CODE="SK-001".
# Built separately so the main host_test is self-contained.
$(TARGET)_crosscheck: crosscheck_main.c verify.c $(ED25519_SRCS) $(HDRS)
	$(CC) $(CFLAGS) -o $@ crosscheck_main.c verify.c $(ED25519_SRCS)

# --------------------------------------------------------------------------
# make test-asan: compile + run host_test under AddressSanitizer (clang only)
#
# Proves the oversized-sig regression case returns 0 with NO overflow report.
# Requires clang with ASan support (macOS: ships with Xcode Command Line Tools;
# Linux: apt install clang).  If clang is unavailable, the bounded decoder
# (dst_cap guard) is the real fix regardless — use `make test` instead.
# --------------------------------------------------------------------------
ASAN_TARGET := $(TARGET)_asan
ASAN_FLAGS  := -std=c99 -Wall -Wextra -O1 -Ied25519 \
               -fsanitize=address -fno-omit-frame-pointer

# SRCS already includes jti_store.c (required by host_test.c)
$(ASAN_TARGET): $(SRCS) $(HDRS)
	clang $(ASAN_FLAGS) -o $@ $(SRCS)

test-asan: $(ASAN_TARGET)
	@echo "--- C host test (AddressSanitizer) ---"
	@./$(ASAN_TARGET)
	@echo ""
	@echo "ASan: no overflow detected (all cases above passed cleanly)"

clean:
	rm -f $(TARGET) $(TARGET)_crosscheck $(ASAN_TARGET) *.o
