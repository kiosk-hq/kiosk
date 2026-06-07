# frozen_string_literal: true

# kiosk-all — meta-gem for the Kiosk production stack.
# `bundle add kiosk-all` pulls in kiosk-core + kiosk-rls + kiosk-server.
# See https://kiosk.tech and design spec §15.4 «Umbrella gems».
#
# Not pulled in (intentional):
#   - kiosk-test-support, kiosk-rls-rspec, kiosk-rls-minitest — host adds
#     these to dev/test groups per their stack.
#   - Adapter gems (kiosk-user-idp-*, kiosk-pay-*, kiosk-credentials-*) —
#     providers pick one per market/stack.

require "kiosk/all/version"

require "kiosk"
require "kiosk/rls"
require "kiosk/server"
