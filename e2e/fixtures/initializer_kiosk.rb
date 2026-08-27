# frozen_string_literal: true

# E2E-specific Kiosk configuration. Overrides the generator-produced
# initializer (which has commented-out fields) with concrete values for
# the demo: synthetic users (uuid), the engine's own agent IdP, two handler
# controllers.
#
# THE VERBS ARE NOT HERE (T-081). They are ordinary Rails controllers under
# app/controllers/kiosk/ — Kiosk::CatalogController (the salons query) and
# Kiosk::BookingsController (the my_appointments query AND the book_appointment
# action, one controller declaring both kinds) — named in `c.handlers`
# below, which is how the engine finds them. What is left in this file is
# configuration, which is what an initializer is for.
#
# The two adapters it wires — StubPsp and DemoAuditSink — are named, not
# required (K-502). Both agent and human authentication are real now and neither
# is stubbed: the human's is `kiosk-user-idp-devise` (T-066), the agent's is the
# engine's own DefaultAgentIdp with no wiring at all (T-104).
# run.sh copies the two adapters to app/services and
# declares that an autoload-ONCE path, which is what makes them resolvable here:
# Rails sets the reloadable autoloader up AFTER config/initializers run, so a
# hand-written `require Rails.root.join(...)` was the only alternative.

# Registration PoW gate uses Equihash (one PoW = Equihash). The params are
# deliberately small — sized to keep the register solve well under a second, the
# same posture the demos ship at their default difficulty — and
# E2E_REGISTRATION_POW_PARAMS below is where they are written down. PoW is a
# metered toll, tuned per provider — here it prices bot registration on the e2e
# golden path so the harness exercises the real 402 → solve → retry handshake,
# not a toll-free shortcut.
#
# NO (n, k) IS RESTATED IN THIS COMMENT (K-1039, the K-1035 class). It named the
# pair a few lines above the constant that defines it, and two further files
# retyped the same pair — three hand-kept copies of one value, which is K-710's
# rot shape one degree colder than the demos': this harness resolves no
# difficulty knob at all, so nothing but a hand edit can move the constant, and
# all three copies were true when they were written. A comment cannot read a
# value, so the repair is to describe the params and let the constant be the one
# place they are stated.
require "kiosk/pow/equihash"
require "kiosk/reputation"
Kiosk::Reputation::Backends.register(Kiosk::Pow::Equihash::NAME, Kiosk::Pow::Equihash)
E2E_REGISTRATION_POW_PARAMS = { n: 96, k: 5 }.freeze

# ── Where this file's env inputs come from (K-1009) ────────────────────────
# Nothing below resolves an environment variable. The PoW HMAC secret, the
# Postgres role names, the issuer and the audit-sink paths are read from ENV
# and published as `Rails.configuration.x.kiosk.*` by the block run.sh splices
# into the generated app's config/environments/{development,production}.rb
# (e2e/fixtures/environment_kiosk.rb) — Phil's ENV-CONFIG-PLACEMENT decision,
# the same split all seven demos carry, enforced here by
# bin/check-demo-copies. That file is also where the postures live: the PoW
# secret's stable dev default and its fail-loud-outside-development raise, and
# the audit sink's «redacted path required only when a sink path is set».

require "kiosk/user_identity_providers/devise"

Kiosk.configure do |c|
  c.user_model     = "User"
  c.user_id_type   = :uuid
  c.user_id_column = :id

  c.guc_namespace  = "app"
  c.schema         = "kiosk"

  # Path C: RLS is optional; no enable_rls_on in this fixture. app_role /
  # system_role are kept for the `run.sh` role pre-creation step (harmless).
  #
  # NOTE (load-bearing): `c.system_role=` is defined ONLY by
  # Kiosk::RLS::ConfigurationExtension (kiosk-rls), which run.sh installs via
  # a path override even though RLS itself is unused here. `app_role` is a
  # kiosk-core attr; `system_role` is not — so this line is why the Gemfile
  # `gem "kiosk-rls"` entry in run.sh is mandatory: dropping the gem makes
  # this call raise NoMethodError at boot.
  c.app_role    = Rails.configuration.x.kiosk.app_role
  c.system_role = Rails.configuration.x.kiosk.system_role

  c.issuer = Rails.configuration.x.kiosk.issuer
  # ONE ROLE, AND THE HARNESS ASSERTS THE BINDING CEREMONY WITH ONE (K-1129).
  #
  # A second declared role was considered and deliberately not added. It would
  # buy the claim-ceremony assertion in `fixtures/claim_flow.rb` a DISTINCTION
  # ("the token came back `customer`, not `owner`") on top of the equality it
  # asserts today — but only if something here actually SOURCED the second role
  # and something GATED on it: a `#kiosk_role` on the User model, a staff column
  # to read it from, a staff human in the seeds, and a query that answers
  # differently per role. Without all four the extra role is a declaration
  # nothing produces and nothing consumes, and this harness is a walkthrough an
  # adopter copies — an inert role would teach that `c.roles` is decoration.
  # With all four it is a second copy of `kiosk-demo-stylish`, which exists and
  # proves exactly that (`demo:roles`, and four binding beats in its redteam
  # suite). So the roles-from-IdP demonstration stays in the demo that is built
  # for it, and the assertion here is the one that does NOT need a second role:
  # the ceremony's unauthenticated opening request refuses `role`/`scope` — at
  # the DECLARED value as much as an invented one — and the minted token carries
  # the approving human's role rather than anything the caller sent.
  c.roles  = %i[customer]
  # Role pinned to every self-registered agent (agents cannot choose their own).
  c.registration_role = :customer
  c.owner  = { name: "Combette E2E Demo", support: "demo@kiosk.tech" }

  # Registration PoW gate: 1 Equihash proof to register. POST /kiosk/auth/register
  # returns 402 pow_required until a valid proof is attached (assistant.sh solves
  # it with the bundled kiosk-pow-equihash/solve.py). Same mechanism the demos use.
  c.registration_pow_count  = 1
  c.registration_pow_params = E2E_REGISTRATION_POW_PARAMS
  c.pow_secret              = Rails.configuration.x.kiosk.pow_secret

  # ── NO c.agent_idp ───────────────────────────────────────────────────────
  # Deliberate, and the point of the line's absence (T-104). An assistant
  # authenticates with the kiosk-pop JWT this very engine minted at
  # `/kiosk/auth/register`, `/auth/login` or the binding ceremony — and the
  # engine already ships the adapter that verifies its own tokens:
  # `IdentityResolution.agent_idp` falls back to
  # `Kiosk::Server::AgentIdentityProviders::DefaultAgentIdp` when nothing is
  # configured. This demo used to override it with a hand-copied composite that
  # re-implemented the JWT half (more loosely — it never checked `iss`) in
  # order to bolt on a dev-only parser turning a self-asserted
  # `agent:u-…:a-…:r-…` string into an identity at any role. Both are gone.
  # SET THIS only to front an EXTERNAL agent-identity issuer (Entra Agent ID,
  # Okta, an ID-JAG-style broker) by subclassing
  # `Kiosk::AgentIdentityProviders::Base` — whose one hard constraint is that
  # the `agent_id` you return must be a UUID (K-830).
  # The provider's own web-session channel (Devise/Warden): authenticates the
  # approving human on the account-binding pages (device verify, link mint,
  # unlink). ONE channel in every environment — this is the shipped
  # kiosk-user-idp-devise adapter reading the request's Warden user, not a
  # stand-in, so an adopter reading this harness copies a real wiring (T-066).
  c.user_idp = Kiosk::UserIdentityProviders::Devise.new

  c.payment_provider = StubPsp.new

  # The handler controllers, by NAME. This line is load-bearing and there is no
  # convention that replaces it: the wire reaches a handler through the
  # registry, nothing else in the app ever references these classes, and this
  # harness boots DEVELOPMENT (eager_load = false), so without it Zeitwerk never
  # loads them, the registry stays empty, and the origin answers `GET
  # /kiosk/schema` with `queries=[] actions=[]`, 404s every query and run, and
  # advertises `"capabilities": []` (K-761).
  c.handlers = %w[Kiosk::CatalogController Kiosk::BookingsController]

  # Request-shape validation ON, as all seven demos have it. Two things ride
  # on it: a malformed Kiosk-PoW proof answers a clear 400 instead of a silent
  # re-challenge loop (K-479), and — since the 0.4 per-verb wire — a verb's
  # declared `input_schema` VALIDATES the arguments of every request to it
  # rather than merely describing them, so the harness's reserved-name and
  # closed-schema assertions are testing the real path. Needs `json_schemer`,
  # which run.sh adds to the generated app's Gemfile.
  c.validate_requests = true

  # T-068 slice 3: every query/action answer is validated against the
  # `output_schema` that verb declares, and a mismatch is a loud 500 rather
  # than a lie shipped to an assistant. A DEVELOPMENT/CI assertion, not a
  # request check — nothing a caller sends can trigger it — and it is what
  # makes this demo's own CI task list a per-verb conformance proof of the
  # descriptors rather than a smoke test.
  c.validate_responses = true

  # ── The audit sink (K-828) ──────────────────────────────────────────────
  # Kiosk stores no audit trail; it emits one ActionEvent per action
  # invocation to whatever callable an operator sets here, and stores nothing
  # itself. THE DEFAULT IS NIL — and this harness proves that too: run.sh
  # boots a SECOND time with KIOSK_AUDIT_SINK_FILE unset, and then this line
  # leaves `audit_sink` nil, no event is built, and nothing is written
  # anywhere.
  #
  # DemoAuditSink (app/services/demo_audit_sink.rb) is the OPERATOR's code, not the
  # engine's: it appends the event to one JSONL file verbatim — arguments and
  # all, because Kiosk hands them over in full and what happens to them is the
  # operator's business and the operator's responsibility — and a redacted
  # copy (`event.with_arg_types`) to a second one, to show that withholding
  # the values is one call at this seam rather than a policy the engine
  # imposed.
  audit_path = Rails.configuration.x.kiosk.audit_sink_file
  c.audit_sink =
    audit_path && DemoAuditSink.new(
      path:          audit_path,
      redacted_path: Rails.configuration.x.kiosk.audit_sink_redacted_file,
    )
end
