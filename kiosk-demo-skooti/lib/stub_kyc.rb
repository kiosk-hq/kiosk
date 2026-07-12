# frozen_string_literal: true

require "openssl"
require "jwt"

# Stub KYC provider for the skooti demo. Uses a fixed dev RSA keypair so
# that both the Rails server (which loads this at boot to configure
# `kyc_public_key`) and the standalone rental_flow.rb driver (which loads
# this in a separate process) share the same signing key.
#
# In production / real KYC integration:
#   - Replace DEV_PEM with an env-loaded PEM or a secrets-manager lookup.
#   - The shape (StubKyc.public_key / StubKyc.attest) stays identical.
#
# StubKyc.public_key   → PEM string (configure in kiosk initializer)
# StubKyc.attest(user_id:) → compact JWS string (submit to POST /kiosk/agents/kyc)
class StubKyc
  # Fixed dev RSA-2048 keypair — stable across processes for the skooti demo.
  # Generated once: `ruby -ropenssl -e "puts OpenSSL::PKey::RSA.generate(2048).to_pem"`
  # DO NOT use in production.
  DEV_PRIVATE_PEM = <<~PEM.freeze
    -----BEGIN RSA PRIVATE KEY-----
    MIIEowIBAAKCAQEAxnSG6WSCpkRiyl4YJdTBkg7ImR1HCKaFyuxHEF1N/3SC6+0W
    p4CvxNeshWEH/sllKb3/cKkOPZhCzuQ1ITDrmcHgjTBjZXdT1Lq8bZ0KPG/puxy/
    gGWO6P1GIYZ4KXoqlvdY0ACn1dFWNL73BzOCN8NKyg/ipiGR1MlZ0eDxqgtonIRR
    jIVAzuYW2B5gCWyZA1P91x5A85wvbLB8Bzhz+TAjzUSprh3/29bWamuGCd7jvKmu
    oMMExjInALnMJz8idoVXpyIoyTxu8wVcGDlmWHaeA9M84mQBhrsNeBxtXZjYx8jV
    vFbeHLzrP/+NpANlFZDVSR5t25zNEZwH53OznwIDAQABAoIBAAn6rxQKZVV2B9+0
    NpOkbK1rB+RHKBzDvuOS2Qn2Hydy1OiHLgXzPyNvUvIMDIpf1zHvp2ojXh9zyhw8
    Nn26R4aeTKvc3IqsIu+GClaauHqMiBzMF8cdlD+cCMxDxkQTrBOWUYV4GvhyA9s4
    JRTcHrauH9MkVFnVQ0+HZnhaztwliuQI3q7y2VGJFiYH7rihJNFzBuG+vhKx2pGJ
    d0rfCFpSDWACQFSeCqYmLiyHCWVkINLEgqh/8apz+pEfbcREIQvv9nH70XlUlWyr
    PZzhvb+lljGmLODfrM3WFrGHPpE7Fhs7HwcQxePnrMkTzIuiWuJnUpDOvf8Gaq+2
    QAs2MpUCgYEA/aGvUasu3yfIPHLWme0Im/upW3zZ2XvbHfzk1mz7xq4ZSeTH7R4E
    D2VM0vB35y/Kh9fLnTwAgP4ZvHFQhKWYhxw6XApIW3xbAI2Nv/3w9x/C+7I4SeXY
    tPQKMGdMvLVFtGHNuIn4V5itiGGjIvrUO678JG7pYP53to7jqLyb1/0CgYEAyE7w
    6L7EPc/KVLwzKyuCmVtrYCWM7yTLupjY+4f04bN2RJllwVm77HyIqvsUwfg318P7
    b/hizE4zmnFtLAfkkpHLteXF/xUtp/BZaJcXBM5oN66tlzOnt4A/823NFI7fQPXo
    S4T12lIRHocoIJi5M1zawxjzOvJ5qregWSZlhssCgYEA3GRG5/yMOjVjdcOEXzTt
    qj1AqNMQqj9J5AEBCKKjFb3rE57Na2oNtSMdYp66UhXhM7F8qSCef3hN/MWqZdlP
    dPg+bgQxY+3nVc+rQQ30+YiL8hKnfu9PI857nBvnPoN2Eox6KsUZG2T8ReoxzA+R
    pFsllrMZ8MKuW+BGSzW5ZjECgYBHMKc2UPZ18W+7hde5tBEKaA9VcIMSS0WM393e
    J4fE339dChe8DCRZ/Dima+4IsitGqASo2uJiMjjs3vsp9vQpk1+PGkawTdqYITfl
    kC1CLAmmIJLZdiZZdV9FKPUGJXD7KWqRzIOEQD6NVwPP8feAZbPqOufXP242WmTG
    ynqy2QKBgEfjf3fJPknV5e/iNUyUnWFwimoMWEThmeCNmCyInHOh1q+6pqX2QYkB
    qpYr2Nl6l/oLLuUdMDQk31wJlaNjeh3cYVC+O5CXdfiXSqTM+NDohP7rKExu9FNU
    BfjGbX4PId77Yv18ELw6N9vCtGPlnKDZ2SmFAyGUfDr2wYwEdN6G
    -----END RSA PRIVATE KEY-----
  PEM

  KEYPAIR = OpenSSL::PKey::RSA.new(DEV_PRIVATE_PEM)
  private_constant :KEYPAIR, :DEV_PRIVATE_PEM

  # The RSA public key PEM string — pass to Kiosk.configuration.kyc_public_key.
  def self.public_key
    KEYPAIR.public_key.to_pem
  end

  # Issue a KYC attestation JWS for the given user_id.
  #
  # @param user_id [String] the user's UUID
  # @return [String] compact RS256 JWS
  def self.attest(user_id:)
    now = Time.now.to_i
    payload = {
      sub:   user_id,
      level: "verified",
      iss:   "https://kyc.example",
      iat:   now,
      exp:   now + 3600,
    }
    JWT.encode(payload, KEYPAIR, "RS256")
  end
end
