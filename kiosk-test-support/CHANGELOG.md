# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/).

How to write an entry, and what a release section means: `CHANGELOG-RULE.md` at
the root of this repository —
<https://github.com/kiosk-hq/kiosk/blob/main/CHANGELOG-RULE.md>. In short: under
200 characters, one or two sentences, the essence rather than the content; write it
under `## [Unreleased]`; a cut renames that heading to
`## [MAJOR.MINOR.PATCH] — <date>` and opens a fresh empty one above it; nothing
already written is edited.

## [Unreleased]

## [0.6.28] — 2026-10-26

- 2026-10-26: Version 0.6.28, the tree cut that matches skill 0.6.28.

## [0.6.27] — 2026-10-26

- 2026-10-26: Version 0.6.27, the tree cut that matches skill 0.6.27.
## [0.6.26] — 2026-10-26

- 2026-10-26: Version 0.6.26, the tree cut that matches skill 0.6.26.
## [0.6.25] — 2026-10-26

- 2026-10-26: Version 0.6.25, the tree cut that matches skill 0.6.25.
- 2026-10-26: The README DSL example seeds, then reads, and says that the assistant helpers call the default mount path `/kiosk`.

## [0.6.24] — 2026-10-26

- 2026-10-26: Version 0.6.24, the tree cut that matches skill 0.6.24.

## [0.6.23] — 2026-10-26

- 2026-10-26: Version 0.6.23, the tree cut that matches skill 0.6.23.

## [0.6.22] — 2026-10-26

- 2026-10-26: Version 0.6.22, the tree cut that matches skill 0.6.22.

## [0.6.21] — 2026-10-26

- 2026-10-26: Version 0.6.21, the tree cut that matches skill 0.6.21.

## [0.6.20] — 2026-10-26

- 2026-10-26: Version 0.6.20, the tree cut that matches skill 0.6.20.

## [0.6.19] — 2026-10-26

- 2026-10-26: Version 0.6.19, the tree cut that matches skill 0.6.19.

## [0.6.18] — 2026-10-25

- 2026-10-25: Version 0.6.18, the tree cut that matches skill 0.6.18.
- 2026-10-25: The gem description and README say that the helpers solve proof-of-work tolls.

## [0.6.17] — 2026-10-25

- 2026-10-25: Version 0.6.17, the tree cut that matches skill 0.6.17.

## [0.6.16] — 2026-10-25

- 2026-10-25: Version 0.6.16, the tree cut that matches skill 0.6.16.
- `SeededDatabase` empties every table on the search path but Rails' own two.

## [0.6.15] — 2026-10-25

- 2026-10-25: Version 0.6.15, the tree cut that matches skill 0.6.15.

- 2026-10-25: `Kiosk::TestHelpers::SkillPin` (Minitest and RSpec): fails when kiosk-server gives a skill that `skill_sha256` is not the digest of, and tells how to make the new digest.

## [0.6.14] — 2026-10-25

- 2026-10-25: Version 0.6.14, the tree cut that matches skill 0.6.14.

## [0.6.13] — 2026-10-25

- 2026-10-25: Version 0.6.13, the tree cut that matches skill 0.6.13.

## [0.6.12] — 2026-10-24

- 2026-10-24: Version 0.6.12, the tree cut that matches skill 0.6.12.

- 2026-10-24: The KYC stand-in replaces `c.kyc_provider` only, and keeps the audience of the provider it stands in for.

## [0.6.11] — 2026-10-24

- 2026-10-24: Version 0.6.11, the tree cut that matches skill 0.6.11.

## [0.6.10] — 2026-10-23

- 2026-10-23: Version 0.6.10, the tree cut that matches skill 0.6.10.

## [0.6.9] — 2026-10-23

- 2026-10-23: Version 0.6.9, the tree cut that matches skill 0.6.9.

## [0.6.8] — 2026-10-22

- 2026-10-22: Version 0.6.8, the tree cut that matches skill 0.6.8.

## [0.6.7] — 2026-10-22

- 2026-10-22: Version 0.6.7, the tree cut that matches skill 0.6.7.

## [0.6.6] — 2026-10-22

- 2026-10-22: Version 0.6.6, the tree cut that matches skill 0.6.6.

## [0.6.5] — 2026-10-22

- 2026-10-22: Version 0.6.5, the tree cut that matches skill 0.6.5.

## [0.6.4] — 2026-10-22

- 2026-10-22: Version 0.6.4, the tree cut that matches skill 0.6.4.

## [0.6.3] — 2026-10-22

- 2026-10-22: Version 0.6.3, the tree cut that matches skill 0.6.3.

## [0.6.2] — 2026-10-22

- 2026-10-22: Version 0.6.2, the tree cut that matches skill 0.6.2.

## [0.6.1] — 2026-10-22

- 2026-10-22: Version 0.6.1, the tree cut that matches skill 0.6.1.
- 2026-10-21: Drops the `kiosk-pow-equihash` and `puma` dependencies; the host's bundle brings them. `Wire` names the gem to add, and refuses a toll in another proof of work.

## [0.6.0] — 2026-10-21

- 2026-10-21: The helpers make Ed25519 assistant keys and sign EdDSA; `Principal#key` replaces `#rsa_key`, and `Dpop.generate_key('ES256')` makes a P-256 key.
- 2026-10-21: Version 0.6.0, the tree cut that matches skill 0.6.0.

## [0.5.27] — 2026-10-21

- 2026-10-21: `Assistant` registers at `/kiosk/oauth/register` and gets tokens by client assertion and DPoP; `login`, `proof_of_possession` and the challenge are gone.
- 2026-10-21: Version 0.5.27, the tree cut that matches skill 0.5.27.

## [0.5.26] — 2026-10-21

- 2026-10-21: Version 0.5.26, the tree cut that matches skill 0.5.26.

## [0.5.25] — 2026-10-21

- 2026-10-21: Version 0.5.25, the tree cut that matches skill 0.5.25.

## [0.5.24] — 2026-10-21

- 2026-10-21: The gemspec depends on kiosk-server and kiosk-user-idp-devise, which the in-process helpers and `Person` require, so a bundle with this gem alone loads them.
- 2026-10-21: Version 0.5.24, the tree cut that matches skill 0.5.24.

## [0.5.23] — 2026-10-21

- 2026-10-21: `Wire#dpop` replaces `Wire#bearer`: each call sends the token as `Authorization: DPoP` with a new proof. `Assistant#rotate` puts a new key on a principal.
- 2026-10-21: Version 0.5.23, the tree cut that matches skill 0.5.23.

## [0.5.22] — 2026-10-21

- 2026-10-21: `Kiosk::TestHelpers::Mandate` signs the two AP2 v0.2 mandates; `Assistant#pay` and `Customer#pays` take a `checkout_jwt`.
- 2026-10-21: Version 0.5.22, the tree cut that matches skill 0.5.22.

## [0.5.21] — 2026-10-21

- 2026-10-21: Version 0.5.21, the tree cut that matches skill 0.5.21.

## [0.5.20] — 2026-10-20

- 2026-10-20: `InProcessOrigin` and `InProcessExecutor` call a verb through its route with a linked assistant's token; `InProcessWire` does the call.
- 2026-10-20: The conformance checks hold an action's arguments to its `input_schema` with no exemption for `limit` or `cursor`, as the wire does.

## [0.5.19] — 2026-10-20

- 2026-10-19: `Wire` and `Assistant::Events` connect to a base URL that names an IPv6 literal, such as `http://[::1]:3001`.

## [0.5.18] — 2026-10-18

- 2026-10-18: Version 0.5.18, the tree cut that matches skill 0.5.18.

## [0.5.17] — 2026-10-18

- 2026-10-18: `StripeMock` runs one stripe-mock per process on free ports unless `STRIPE_MOCK_URL` names one; `StripeMock.url` replaces `URL`.

## [0.5.16] — 2026-10-18

- 2026-10-18: The Stripe test front answers a refund that names no charge with a 400, as Stripe does.

## [0.5.15] — 2026-10-18

- 2026-10-18: `Kiosk::TestHelpers::Customer#pays_cart(cart, scope:)` signs the `cart` an action answered with and pays.

- 2026-10-18: `Kiosk::StoryTest#assert_refused(answer, code)` asserts a wire refusal and prints the answer when it fails.

- 2026-10-18: Declares `puma`, which the live server helper requires; a RubyGems install no longer fails to load it.

## [0.5.14] — 2026-10-18

- 2026-10-18: Version 0.5.14, the tree cut that matches skill 0.5.14.

- 2026-10-17: New `kiosk/test_helpers/small_equihash`: required from test setup, it makes the Equihash default n=96 k=5 so test registrations stay fast.

- 2026-10-17: Adds InProcessExecutor and Conformance::InProcessOrigin, moved from kiosk-server. Require them explicitly; they run against the host's kiosk-server.

- 2026-10-17: `Assistant#pay` calls `payment_setup` when `pay` answers `payment_setup_required`, then pays once more.

- 2026-10-17: `Customer#leaves` is removed; nothing called it.
- 2026-10-17: `Person#links_a_newcomer` links a newly keyed assistant to the signed-in person, for scripts that need a bound principal.

## [0.5.13] — 2026-10-11

- 2026-10-11: Version 0.5.13, the tree cut that matches skill 0.5.13.

- 2026-10-09: **A story's `Person` links, approves and unlinks assistants**, and a `Customer` pays a quote, signs back in, follows news checked against its schema; `kiosk/story_spec` is RSpec's form.

- 2026-10-09: **`Kiosk::StoryTest` and `Kiosk::TestHelpers::Story`** let a test tell an operator's business story through a `Customer` who asks, does, pays and hears.

- 2026-10-09: **`Assistant` drives an origin as an assistant does; `Kyc` stands in for the KYC provider** so a test decides how a check ends. `Wire` and `StripeMock` move here.

- 2026-10-09: **`LiveServer` and `SeededDatabase`** serve the app over HTTP from the test process on committed, seeded data; **`DescriptorExamples`** checks each published example against its schema.

## [0.5.12] — 2026-10-08

- 2026-10-08: Version 0.5.12, the tree cut that matches skill 0.5.12; this gem's surface is unchanged.

## [0.5.11] — 2026-10-08

- 2026-10-08: Version 0.5.11, the tree cut that matches skill 0.5.11; this gem's surface is unchanged.

## [0.5.10] — 2026-10-08

- 2026-10-08: Version 0.5.10, the tree cut that matches skill 0.5.10; this gem's surface is unchanged.

## [0.5.9] — 2026-10-08

- 2026-10-08: Version 0.5.9, the tree cut that matches skill 0.5.9; this gem's surface is unchanged.

## [0.5.8] — 2026-10-07

- 2026-10-07: Version 0.5.8, the tree cut that matches skill 0.5.8; this gem's surface is unchanged.

## [0.5.7] — 2026-10-07

- 2026-10-07: Version 0.5.7, the tree cut that matches skill 0.5.7; this gem's surface is unchanged.

## [0.5.6] — 2026-10-07

- 2026-10-07: Version 0.5.6, the tree cut that matches skill 0.5.6; this gem's surface is unchanged.

## [0.5.5] — 2026-10-07

- 2026-10-07: Version 0.5.5, the tree cut that matches skill 0.5.5; this gem's surface is unchanged.

## [0.5.4] — 2026-10-07

- 2026-10-07: Version 0.5.4, the tree cut that matches skill 0.5.4; this gem's surface is unchanged.

## [0.5.3] — 2026-10-06

- 2026-10-06: Version 0.5.3, the tree cut that matches skill 0.5.3; this gem's surface is unchanged.

## [0.5.2] — 2026-10-06

- 2026-10-06: Version 0.5.2, the tree cut that matches skill 0.5.2; this gem's surface is unchanged.

## [0.5.0] — 2026-09-26

### Removed

- **`NullExecutor#identity_stack` is no longer public, and `enqueue_action` is now `enqueue_run_action` (K-1708).** Ask `current_identity`; every rig helper is named for the kind it queues.

- **`Conformance::Verb#action?` and `Conformance::Outcome#to_s`, neither of which had a caller anywhere (K-1703).** `kind` and `message` are public and say the same.

### Changed

- **`have_a_route_for_every_verb` took no block parameter, so `origin:` was accepted and discarded (K-1702).** It now honours the keyword its Minitest twin honours.

- **The published journey-helper roll-call was short by `run_query` (K-1696).** The lists name it now, and the two «helpers are available» tests are held to the module rather than to themselves.

- The route conformance check no longer special-cases the engine's refusal controller, which no longer exists: a declared verb whose route is missing is reported as declared-and-never-routed, which is what every caller now meets as an ordinary 404.
- README: every `gem` line in the install section now carries `github: "kiosk-hq/kiosk"`, so a copied line resolves before publication; the banner above them states what the block does rather than asking the reader to add it.
- Dropped the `kiosk-rls` dependency (RLS is opt-in now). This gem never
  used `Kiosk::RLS` constants — `Errors::RLSDenied` is its own class and
  stays.

### Added

- `Kiosk::TestHelpers::Conformance` — four checks an origin runs against itself for the four properties the protocol makes normative of it: that its routes resolve, that a verb executes, that a query answers the shape it declared, and that data access is scoped to the authenticated principal. Inert until an origin is wired (`Conformance.origin=`); `kiosk-server` ships the real one.
- Two adapters, loaded by explicit require so this gem still depends on no test framework: `kiosk/test_helpers/conformance/minitest` (`assert_kiosk_verbs_routed`, `assert_kiosk_verb_executes`, `assert_kiosk_answer_matches_declared_schema`, `assert_kiosk_scoped_to_principal`) and `kiosk/test_helpers/conformance/rspec` (`have_a_route_for_every_verb`, `execute_as_a_kiosk_verb`, `answer_its_declared_schema`, `be_scoped_to_principal`). Both render the same failure sentence.
- `Kiosk::TestHelpers::Conformance::NullOrigin` — the zero-dependency reference implementation of the origin contract, for unit-shaped tests with no Rails and no database.
- `Journey#run_query(name, **args)` and a matching `run_query` on the executor contract. `query` takes SQL; without this, a declared `kind :query` verb was reachable through nothing.
- `Errors::OriginNotConfigured` and `Errors::SchemaValidatorMissing`, both carrying wiring instructions.

- Initial skeleton.
- `Kiosk::TestHelpers::Journey` module — the journey-test DSL: `as_agent_of`, `as_user`, `as_agent`, `as_anonymous`, `query`, `run_action`, `pay_action`, `kiosk_seed`.
- Pluggable executor contract — `Kiosk::TestHelpers.executor=` accepts any object responding to `with_identity(identity, &block)`, `query(sql)`, `run_action(name, args)`, `pay_action(name, args)`, `seed(table, attrs, count:)`. Default is unset; raises `Kiosk::TestHelpers::Errors::ExecutorNotConfigured` until wired.
- `Kiosk::TestHelpers::NullExecutor` — records calls into an inspectable array; queues seeded results. Used by this gem's own specs and by `kiosk-rls-rspec` / `kiosk-rls-minitest` self-tests; `kiosk-server` ships the real `Kiosk::Server::TestExecutor` for production-shaped tests.
- `Kiosk::TestHelpers::Errors` — `RLSDenied`, `QuotaExceeded`, `ExecutorNotConfigured`. Used by the framework-specific matchers / assertions.

### Notes on the three-gem split

The journey-test DSL was originally scoped to live inside `kiosk-rls-rspec` and `kiosk-rls-minitest`. We split the shared module out into this third gem so both harness gems can `include Kiosk::TestHelpers::Journey` without duplication or one harness depending on the other. The two harness gems remain ≤200 LOC each (framework wiring only); the shared DSL fits in ≤400 LOC here.
