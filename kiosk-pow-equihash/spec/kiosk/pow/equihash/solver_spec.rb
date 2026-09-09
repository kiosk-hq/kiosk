# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

# The verifier and the solver are two halves of one algorithm with two very
# different threat positions, and the load boundary between them is the whole
# safety property here: a provider runs `verify` on an UNAUTHENTICATED
# `POST /auth/register`, so nothing it loads on that path may be able to spawn a
# process. `kiosk/pow/equihash` is therefore free of `open3`, and `solve` lives
# behind its own require.
#
# It is asserted in a FRESH PROCESS because this one has already loaded the
# whole gem: inside the suite the constant is defined no matter what the
# boundary says, so an in-process check would pass while the boundary was gone.
RSpec.describe "the solver/verifier load boundary" do
  LIB = File.expand_path("../../../../lib", __dir__)

  def ruby(code)
    Open3.capture2e(RbConfig.ruby, "-I", LIB, "-e", code)
  end

  it "does not give the verifier a `solve` method" do
    out, status = ruby(<<~RUBY)
      require "kiosk/pow/equihash"
      exit(Kiosk::Pow::Equihash.respond_to?(:solve) ? 1 : 0)
    RUBY

    expect(status).to be_success,
                      "requiring the verifier defined .solve — the solver is back on the " \
                      "provider's unauthenticated register path:\n#{out}"
  end

  it "does not load open3 into the verifier" do
    out, status = ruby(<<~RUBY)
      require "kiosk/pow/equihash"
      exit(defined?(Open3) ? 1 : 0)
    RUBY

    expect(status).to be_success, "requiring the verifier loaded open3:\n#{out}"
  end

  it "does give the difficulty knob to the verifier — it is ENV-only and costs nothing" do
    out, status = ruby(<<~RUBY)
      require "kiosk/pow/equihash"
      exit(Kiosk::Pow::Equihash::Difficulty.respond_to?(:params) ? 0 : 1)
    RUBY

    expect(status).to be_success, out
  end

  it "defines `solve` when the solver is required" do
    out, status = ruby(<<~RUBY)
      require "kiosk/pow/equihash/solver"
      exit(Kiosk::Pow::Equihash.respond_to?(:solve) ? 0 : 1)
    RUBY

    expect(status).to be_success, out
  end

  it "loads standalone, without the verifier having been required first" do
    out, status = ruby(<<~RUBY)
      require "kiosk/pow/equihash/solver"
      exit(Kiosk::Pow::Equihash.respond_to?(:verify) ? 0 : 1)
    RUBY

    expect(status).to be_success,
                      "the solver does not pull in the module it extends:\n#{out}"
  end
end

RSpec.describe "Kiosk::Pow::Equihash.solve" do
  before { require "kiosk/pow/equihash/solver" }

  it "raises SolverError, not an unhandled exception, when the solver refuses" do
    # `{}` has no `salt`/`params`, so solve.py exits non-zero. A driver aborts
    # on the message; nothing here may surface a Python traceback as a crash.
    expect { Kiosk::Pow::Equihash.solve({}) }
      .to raise_error(Kiosk::Pow::Equihash::SolverError)
  end
end
