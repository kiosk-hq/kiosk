# frozen_string_literal: true

# The kiosk-pow-equihash known-answer proof, in one place. Two spec files drive
# the real verifier with it, and a constant assigned at the top of an
# `RSpec.describe` block lands in Object rather than on the example group — so a
# file naming its own would redefine the other's, and the suite would say so on
# every run to nobody.
module EquihashKat
  SALT   = "kat"
  PARAMS = { n: 8, k: 1 }.freeze
  NONCE  = { indices: [2, 10] }.freeze
end
