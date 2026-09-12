# Security policy

Kiosk is a protocol and the reference implementation of it. The parts of this
repository that carry security weight are the ones an origin exposes to the open
internet: the register/login proof-of-possession handshake, the JWT-bearing data
plane, the proof-of-work gate in front of registration, the payment path that
settles a cart mandate against a card saved on the provider's own PSP account,
and the optional Postgres row-level-security backstop. A flaw in any of those
lets someone reach data or money that is not theirs on a **running operator's**
server, and it should reach us before it reaches them.

## Reporting a vulnerability

**Do not open a public issue for a security report, and do not post one in a
pull request.** Public issues are the right channel for everything else — see
[CONTRIBUTING.md](CONTRIBUTING.md) — and the wrong one for a flaw that can be
used against a live origin before its operator can patch.

<!-- SECURITY-CONTACT-UNSET -- the reporting channel is not decided yet; this
     placeholder must be replaced before this repository is made public. -->

> ⚠️ **The private reporting channel is not published yet, so this section is
> incomplete.** Everything else on this page is accurate today. Until the
> channel is here, please contact the maintainer through the address in any
> `*.gemspec` in this repository rather than filing publicly, and say in the
> first line that the report is a security one.

Whatever the channel, a report is most useful when it carries:

- the **version or commit** you were looking at (no release is tagged yet — see
  *Which versions get fixes* below, so a commit sha is the precise answer);
- which **gem or demo** the flaw is in, and whether it is in the framework or
  only in a demo application built on it;
- the **shortest sequence of requests** that shows it — a failing spec, a
  `curl` transcript, or a `kiosk-redteam` scenario is ideal;
- what an attacker **gets**: whose data, whose money, or whose identity.

Please give us a chance to ship a fix before you publish. We will credit you in
the changelog entry for the fix unless you ask us not to.

## Which versions get fixes

There is no release tag in this repository and nothing is on RubyGems yet; every
gem sits on the same `0.4` protocol line and is installed from git. In practice
that means **the fix lands on `main` and there is no back-port branch to ask
for.** When releases start, this section says which lines are supported.

## What is in scope

Anything in the shipped gems (`kiosk-core`, `kiosk-server`, the PoW backends,
`kiosk-reputation`, `kiosk-rls*`, the IdP and PSP adapters, `kiosk-test-support`,
`kiosk-redteam`) and anything in the `e2e/` harness. A flaw in one of the
`kiosk-demo-*` applications is in scope too when it is a flaw a reader would
copy — these demos exist to be read and imitated, so a bad pattern in one of
them propagates.

## What is not a vulnerability here

Each of these is deliberate, documented where it lives, and reported often
enough to be worth naming:

- **The two development keypairs this repository tracks on purpose**
  (`kiosk-demo-skooti/config/dev_unlock_key.pem`,
  `kiosk-demo-prove/config/dev_prove_key.pem`). They are burned by design: each
  file carries a do-not-use banner in its own header, each application refuses to
  boot in production without an explicit key, and `bin/check-publication-paths`
  fails on any *third* tracked private key and on either of these two if it loses
  its banner. A report that a private key is committed here tells us something we
  wrote down first. A report that one of them is reachable from a **production**
  boot path is a real finding.
- **Equihash is neither ASIC- nor GPU-proof.** The proof-of-work gate is metered
  pricing, not a hardware wall; `kiosk-pow-equihash/README.md` says so at the
  top. Abuse resistance comes from the reputation policy's proof-count knob and
  caps. "A GPU solves this faster than a laptop" is the design, not a bug.
- **Demo seed data, demo credentials and demo hosts.** The `kiosk-demo-*` apps
  seed fictional people and orders and log in without a password in development.
- **`kiosk-pay-stripe`'s test-mode helpers** (`test_payment_method`,
  `test_autocard`). They exist so suites need no hosted card-entry step, and the
  README says never to enable them in production or a live demo.
- **Findings your own `kiosk-redteam` battery reports against your own origin.**
  That gem is an adversarial test harness; a red beat against an application you
  wrote is the harness working. A gap it reveals in the **engine** — a check the
  framework should have made and does not — is a real report, and a welcome one.

## What is not covered by this policy

Vulnerabilities in Rails, Postgres, Stripe, `numpy`, or any other dependency
belong to that project's own security process. Report them there; if the fix
needs a change on our side too, tell us and we will make it.
