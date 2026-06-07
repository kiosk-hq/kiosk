# frozen_string_literal: true

# Loaded standalone from the gemspec (which can't `require "kiosk"` —
# kiosk-core isn't on the load path at gem-build time). Defines just the
# version constant under a namespace module; the actual adapter class
# `Kiosk::UserIdentityProviders::Devise` lives in
# `kiosk/user_identity_providers/devise.rb` and is loaded at runtime.
module Kiosk
  module UserIdentityProviders
    module DeviseVersion
      VERSION = "0.0.1"
    end
  end
end
