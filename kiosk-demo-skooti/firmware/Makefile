# Makefile — skooti firmware host crypto test
#
# Targets:
#   make test        — compile + run C host test + Ruby crosscheck
#   make crosscheck  — Ruby ↔ C HMAC parity check only
#   make build       — compile only (no run)
#   make clean       — remove build artefacts
#
# The .ino is NOT compiled here (requires the ESP32 Arduino toolchain).
# See README.md for flashing instructions.

CC      ?= cc
CFLAGS  := -std=c99 -Wall -Wextra -Wpedantic -O2
SRCS    := hmac_sha256.c verify.c host_test.c
TARGET  := host_test

# Expected MAC — the C test and the Ruby crosscheck must both produce this.
EXPECTED_MAC := 896eec16ca0d164293762269f0d34c319a41b4a463bedc2ce11f3269a49e9b1f

# K_lock as hex for the Ruby one-liner (= HMAC-SHA256("dev-master-key-0001","SK-001"))
KLOCK_HEX := d147ea9da6b6957f83e46a58cb3e7aa56e4025497143b0897f68aa05e2fd842a

.PHONY: all build test crosscheck clean

all: test

build: $(TARGET)

$(TARGET): $(SRCS) hmac_sha256.h verify.h
	$(CC) $(CFLAGS) -o $@ $(SRCS)

# --------------------------------------------------------------------------
# make test: compile, run C test, then run Ruby crosscheck
# --------------------------------------------------------------------------
test: build
	@echo "--- C host test ---"
	@./$(TARGET)
	@echo ""
	@$(MAKE) --no-print-directory crosscheck

# --------------------------------------------------------------------------
# make crosscheck: Ruby (OpenSSL) ↔ C HMAC parity
#
# Runs a one-liner Ruby script that recomputes the same MAC using
# OpenSSL::HMAC — exactly the same code path as the Kiosk server —
# and compares it to the expected value.  Proves C↔Ruby HMAC parity.
# --------------------------------------------------------------------------
crosscheck:
	@echo "--- Ruby ↔ C crosscheck ---"
	@RUBY_MAC=$$(ruby -e ' \
	  require "openssl"; \
	  k = ["$(KLOCK_HEX)"].pack("H*"); \
	  puts OpenSSL::HMAC.hexdigest("SHA256", k, "SK-001|00112233445566778899aabbccddeeff|resv-1") \
	') && \
	echo "  Ruby  mac : $$RUBY_MAC" && \
	echo "  C     mac : $(EXPECTED_MAC)" && \
	if [ "$$RUBY_MAC" = "$(EXPECTED_MAC)" ]; then \
	  echo "  MATCH — C HMAC == Ruby/OpenSSL (server) HMAC ✓"; \
	else \
	  echo "  MISMATCH — C HMAC != Ruby/OpenSSL !"; \
	  exit 1; \
	fi

clean:
	rm -f $(TARGET) *.o
