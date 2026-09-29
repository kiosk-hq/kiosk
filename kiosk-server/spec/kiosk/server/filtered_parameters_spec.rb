# frozen_string_literal: true

# What a Kiosk origin keeps OUT of its request log. Rails writes the
# `Parameters:` line at `info`, which is what a deployed demo runs at, so the
# credential-bearing fields of the wire have to be in the host's
# `filter_parameters` — and the engine puts them there, because it is the
# thing that knows their names.
#
# The probe app (spec/support/filtered_parameters_probe_app.rb) is a real,
# booted Rails::Application with kiosk-server mounted and nothing else — no
# config/initializers/filter_parameter_logging.rb — run ONCE as a subprocess
# with Rails.logger pointed at a StringIO. This file asserts on the log it
# captured.

require "open3"

module FilteredParametersProbe
  PROBE = File.expand_path("../../support/filtered_parameters_probe_app.rb", __dir__)

  def self.report
    @report ||= begin
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, PROBE)
      unless status.success?
        raise "filtered parameters probe app failed (#{status.exitstatus}):\n" \
              "--- stdout ---\n#{stdout}\n--- stderr ---\n#{stderr}"
      end
      JSON.parse(stdout)
    end
  end

  def self.log = report.fetch("log")
  def self.sent(field) = report.fetch("sent").fetch(field)
end

RSpec.describe "the credential-bearing wire fields in the request log" do
  let(:log) { FilteredParametersProbe.log }

  # Each field, and what the specification says it is.
  {
    "signed"              => "the possession proof (§5.2), on register, claim and the token poll",
    "code"                => "the link code redeemed at /auth/claim (§6.2)",
    "device_code"         => "the device code presented on the token poll (§6.1)",
    "kyc_jws"             => "the KYC attestation (§12)",
    "intent_mandate_jws"  => "the intent mandate (§11)",
    "cart_mandate_jws"    => "the cart mandate (§11)",
    "payment_mandate_jws" => "the payment mandate (§11)",
  }.each do |field, what|
    it "filters #{field} — #{what}" do
      expect(log).to match(/"#{field}"\s*=>\s*"\[FILTERED\]"/)
      expect(log).not_to include(FilteredParametersProbe.sent(field))
    end
  end

  # The control: without it every assertion above would also pass on a log
  # that carries no parameter values at all.
  it "leaves public_key in the clear — §5: a public key is not a credential" do
    expect(log).to include(FilteredParametersProbe.sent("public_key"))
  end

  it "logs a Parameters line for every endpoint the probe dialed" do
    expect(log.scan(/^  Parameters: /).length).to eq(5)
  end

  # The access token is presented in a header, and Rails' request log prints
  # no headers — only `Started <method> "<filtered path>"` and `Parameters:`.
  it "never writes the access token to the log" do
    expect(log).not_to include(FilteredParametersProbe.report.fetch("bearer"))
  end
end
