# Kiosk roadmap

## Why Kiosk exists

More and more people will hand errands to a personal AI assistant: book a
table, order groceries, rent a scooter. Kiosk lets a business serve those
assistants directly, over plain HTTPS, at its own website. Any assistant can
come: one from a large platform, or one a person runs on their own laptop.
Nobody has to accredit it first. The assistant makes its own key, opens an
account at that one site, and pays a small proof-of-work toll, so that a new
account costs real work and abuse stays expensive. Money goes from the
customer's card to the business's own payment provider, with nobody in the
middle. Let's Encrypt made TLS free for every website. Kiosk aims to make
every business open to every assistant, with no gatekeeper.

Other efforts have the same aim. The Personal Agent Protocol (Poppy, from
Sierra and Meta, first draft in October 2026) names an assistant by an HTTPS
URL that serves its metadata, with its keys on the same domain. Kiosk needs only
a key the assistant made itself, and the toll. That is the edge we keep
building on.

## 0.6: what we show

0.6 packages what works today, with seven demo operators live:

- **An account per assistant, per site.** The assistant proves it holds a key,
  solves the toll, and gets tokens bound to that key (DPoP). It can change its
  key and keep its account. The customer links it to their own account, and
  can remove it.
- **Operations.** The business publishes what an assistant may read and do.
  Each operation has its own path and a JSON Schema for its input.
- **Payments.** The customer saves a card once on the business's own Stripe
  page. The assistant pays a checkout that the business signs, with AP2 v0.2
  mandates, and gets signed receipts back. The customer can cap what one
  payment of each assistant may charge.
- **Age and licence checks.** An action can require a fact about the customer
  from an identity-check service. The demo service only asks the customer.
- **Events.** The business tells the assistant about a change (an order
  shipped, a room confirmed) over one connection that the assistant opens.
  The assistant needs no public address.
- **Discovery.** Standard files tell an assistant what the site offers and
  where the skill is: agents.txt, the API catalogue, OAuth server metadata,
  the agent skills index.
- **One specification, one skill.** kiosk.tech/specification.html defines the
  protocol. kiosk.tech/skill.md teaches it to an assistant.
- **A Ruby on Rails reference implementation**, in this repository.

## 0.7: stronger where others are weak

- The identity check takes a fact from a government credential (a mobile
  driving licence first), in place of the demo's self-asserted answer.
- One adapter for an external agent-identity issuer, chosen by a free tier
  and the least work.
- AP2 open mandates: the customer signs limits with their own key, and the
  assistant buys within them later, while the customer is away.
- A client script on kiosk.tech that an assistant runs, so that it does not
  write its own client first.
- DNS records (DNS-AID) that point an assistant at each demo.
- Find out whether a Kiosk operator can also answer Poppy's business side.
- Consider UCP: should a commerce operator also serve it, for platform
  assistants?

## 0.8

- Stripe Shared Payment Tokens, and MPP, as more ways to pay.

## Later

- Deductions: store credit, gift cards, codes and discounts lower a total.
- More agent-identity issuers: Microsoft Entra Agent ID, Okta, Google, and the
  IETF identity assertion grant.
- Prices in the assistant's currency.
- Human sign-in beyond Devise (OIDC, SAML), when an operator asks for it.

## Under consideration

Ideas we have not decided on. They are not promises.

- An open, free service that vouches a checked human stands behind an
  assistant, without saying who.
- x402 as an alternative to the proof-of-work toll: the assistant pays a
  small sum per call over HTTP 402, in place of computing a proof.

## Out of scope

- **Implementations in other languages** (Go, Python, Node) wait until people
  ask for them. The specification and the JSON Schemas are there for anyone
  who ports it.
- **A directory of operators.** Kiosk works per site. An assistant finds a
  business the way a person does, and then reads its discovery files.
