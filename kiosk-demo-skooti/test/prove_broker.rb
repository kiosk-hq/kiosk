# frozen_string_literal: true

require "net/http"

# kiosk-demo-prove, the KYC broker this operator calls, served once per test run.
module ProveBroker
  APP = File.expand_path("../../kiosk-demo-prove", __dir__)
  LOG = File.expand_path("../log/prove-broker.log", __dir__)

  def self.start
    @start ||= begin
      url = URI(ENV.fetch("KIOSK_PROVE_BROKER_URL"))
      env = {
        "RAILS_ENV"                        => "development",
        "PROVE_PUBLIC_URL"                 => url.to_s,
        "KIOSK_PROVE_ISSUER"               => ENV.fetch("KIOSK_PROVE_ISSUER"),
        "KIOSK_PROVE_SKOOTI_SECRET"        => ENV.fetch("KIOSK_PROVE_INTAKE_SECRET"),
        "KIOSK_PROVE_SKOOTI_CALLBACK_HOST" => "127.0.0.1",
      }
      Bundler.with_unbundled_env do
        system(env, "bin/rails", "db:drop", "db:create", "db:schema:load", "db:seed",
               chdir: APP, out: LOG, err: LOG, exception: true)
        pid = spawn(env, "bin/rails", "server", "-b", url.host, "-p", url.port.to_s,
                    chdir: APP, out: LOG, err: LOG)
        at_exit { Process.kill("TERM", pid) }
      end
      wait_for(url + "/prove_key.pem")
    end
  end

  def self.wait_for(uri)
    60.times do
      return true if serving?(uri)
      sleep 0.5
    end
    raise "the KYC broker did not start; see #{LOG}"
  end

  def self.serving?(uri)
    Net::HTTP.get_response(uri).is_a?(Net::HTTPSuccess)
  rescue SystemCallError
    false
  end
end
