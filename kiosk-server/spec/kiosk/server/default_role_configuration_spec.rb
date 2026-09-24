# frozen_string_literal: true

# T-225 — «there is always a default role» becomes a property of the ENGINE.
#
# K-1791 made both branches of `AccountBinding.bind!` resolve their role the
# same way: the ceremony's role, else `config.registration_role`. What it could
# not do is guarantee the fallback resolves to anything — `registration_role`
# was a bare accessor with no value and no load-time check, so an origin that
# declared a role vocabulary and configured no default still landed every
# role-less ceremony, and every self-registration, on the EMPTY role set. The
# rule held because all eight shipped configurations happen to set `:customer`.
#
# The requirement is CONDITIONAL, and the condition is what keeps ADR-0011's
# protected operator untouched: an origin that declares `c.roles` must also
# configure `registration_role`; an origin that declares no role vocabulary is
# exactly as it was — no role reaches its bindings, its tokens omit the `role`
# claim, and it boots.
#
# The condition lives on the engine class rather than inside its
# `after_initialize` block for the reason `.shared_spent_store_warning` does:
# a block body is reachable only by booting a real application, and a control
# whose condition cannot be unit-tested is a control nobody can prove fires.
# That the block RAISES on it is proven separately, against a real boot, in
# default_role_boot_spec.rb.
RSpec.describe Kiosk::Server::Engine, ".default_role_configuration_error" do
  def error(config: Kiosk.configuration)
    described_class.default_role_configuration_error(config: config)
  end

  context "when the origin declares a role vocabulary" do
    before { Kiosk.configure { |c| c.roles = %i[customer owner] } }

    it "refuses a configuration that names no default role" do
      expect(error).to include("registration_role")
    end

    it "names the setting to add and a value it would accept" do
      expect(error).to include("c.registration_role = :customer")
    end

    it "names the other supported shape, so the operator has both exits" do
      expect(error).to include("c.roles = []")
    end

    it "says what the misconfigured origin would DO, not merely that it is wrong" do
      expect(error).to include("role claim")
    end

    it "is silent once a default role is configured" do
      Kiosk.configure { |c| c.registration_role = :customer }
      expect(error).to be_nil
    end

    # `registration_role` is read through `to_s.strip.empty?` everywhere it is
    # consumed (agent_registration.rb, account_binding.rb), so an empty string
    # means UNSET there. It has to mean unset here too, or the engine boots an
    # origin whose every resolution then lands on the empty role set.
    it "treats an empty-string default as unset — the reading every consumer makes" do
      Kiosk.configure { |c| c.registration_role = "  " }
      expect(error).to include("registration_role")
    end

    it "accepts a default spelled as a String" do
      Kiosk.configure { |c| c.registration_role = "customer" }
      expect(error).to be_nil
    end
  end

  # ADR-0011's protected operator: roles are hook-or-absent, and «registration
  # MUST NOT fail when [registration_role] is unset». This is the arm that keeps
  # that true — the amendment narrows the decision, it does not repeal it.
  context "when the origin declares NO role vocabulary" do
    it "is silent with no default role configured — nothing has changed for it" do
      expect(Kiosk.configuration.roles).to eq([])
      expect(error).to be_nil
    end

    it "is silent whether the vocabulary is empty or never set at all" do
      Kiosk.configure { |c| c.roles = [] }
      expect(error).to be_nil
    end
  end

  # A default outside the declared vocabulary is a different defect and already
  # has an owner — `AgentRegistration.call` raises ConfigurationError on it. This
  # check must not silently accept it as «a default is present», nor duplicate
  # the message: it reports the same misconfiguration at BOOT instead of at the
  # first registration, which is the whole point of moving the question earlier.
  it "refuses a default that is not one of the declared roles" do
    Kiosk.configure { |c| c.roles = %i[customer]; c.registration_role = :admin }
    expect(error).to include("admin")
    expect(error).to include("registration_role")
  end
end
