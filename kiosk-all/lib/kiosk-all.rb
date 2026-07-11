# frozen_string_literal: true

# kiosk-all — meta-gem for the Kiosk production stack.
# `bundle add kiosk-all` pulls in kiosk-core + kiosk-server.
# See https://kiosk.tech.
#
# Not pulled in (intentional):
#   - kiosk-rls — opt-in DB-level defense-in-depth; hosts that want RLS
#     add it explicitly (see the kiosk-rls README).
#   - kiosk-test-support, kiosk-rls-rspec, kiosk-rls-minitest — host adds
#     these to dev/test groups per their stack.
#   - Adapter gems (kiosk-user-idp-*, kiosk-pay-*) — providers pick one
#     per market/stack.

require "kiosk/all/version"

require "kiosk"
require "kiosk/server"
