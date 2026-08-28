# frozen_string_literal: true

require "spec_helper"

# The oracle every hostile-shape beat in the fleet asks "did the RUNTIME speak?"
# with (T-121). What is pinned here is not that it finds leaks — the pre-fix
# `include?` did that — but that it stops being a function of what the ATTACKER
# sent, in both directions:
#
#   * an echoed needle must NOT be called a leak (the false BREACH this closes),
#   * a genuine needle must STILL be called one, including when the probe's own
#     value is sitting inside the very sentence that leaked (the false NEGATIVE
#     a `gsub`-based subtraction would have introduced).
#
# Every example states the OLD oracle's answer beside the new one wherever they
# differ, so the regression this file prevents is visible in the file itself.
RSpec.describe Kiosk::Redteam::LeakScan do
  # The vocabulary the fleet's beats actually forbid (the union of atablefor's
  # SHAPE_LEAKS, hoteling's and skooti's LEAKS, and every SQL_INTERNALS copy).
  NEEDLES = ["NoMethodError", "undefined method", "TypeError", "no implicit conversion",
             "::uuid", "::integer", "::date", "PG::", "22P02", "invalid input syntax",
             "ActiveRecord::", "ActiveModel::"].freeze

  # The oracle as it stood before this module existed, so "removing the fix"
  # is something this spec can EXECUTE rather than something a comment claims.
  def pre_fix_oracle(body)
    raw = JSON.generate(body)
    NEEDLES.find { |needle| raw.include?(needle) }
  end

  # A refusal shaped exactly like the ones these beats meet: an RFC 9457
  # problem document whose `detail` names the value it got.
  def refusal(detail)
    problem("bad_request", detail: detail)
  end

  # ── The false BREACH this closes ────────────────────────────────────────────

  context "when the ONLY occurrence of a needle is the probe's own echoed value" do
    let(:junk) { "PG::22P02 invalid input syntax" }
    let(:body) { refusal(%(neighborhood #{junk.inspect} is not one this aggregator serves — currently Alfama)) }

    it "reports NO leak" do
      expect(described_class.leak(body, NEEDLES, supplied: { neighborhood: junk })).to be_nil
    end

    it "would have been a BREACH under the pre-fix oracle" do
      expect(pre_fix_oracle(body)).to eq("PG::")
    end

    it "names every discounted needle rather than swallowing the judgement" do
      result = described_class.scan(body, NEEDLES, supplied: { neighborhood: junk })

      expect(result.leak?).to be(false)
      expect(result.echoed).to contain_exactly("PG::", "22P02", "invalid input syntax")
      expect(result.note).to include("echoed, not leaked")
    end
  end

  # ── The genuine leak that must still be found ───────────────────────────────

  context "when the runtime spoke" do
    it "finds a needle in a sentence the probe did not supply" do
      body = refusal("PG::InvalidTextRepresentation: invalid input syntax for type uuid")

      expect(described_class.leak(body, NEEDLES, supplied: { booking_id: "not-a-uuid" })).to eq("PG::")
    end

    it "finds a needle even when the echoed value sits INSIDE the leaking sentence" do
      body = refusal(%(PG::InvalidTextRepresentation: invalid input syntax for type uuid: "not-a-uuid"))

      expect(described_class.leak(body, NEEDLES, supplied: { booking_id: "not-a-uuid" })).to eq("PG::")
    end

    # THE `gsub` REJECTION, EXECUTED. A probe value that is a SUBSTRING of a
    # needle is what makes blind subtraction unsafe: deleting `input syntax`
    # from the body destroys the `invalid input syntax` around it and the real
    # breach reads clean. The positional scan keeps it, because the genuine
    # occurrence STARTS BEFORE the echoed span and so is not contained by it.
    it "keeps a needle whose bytes merely OVERLAP the echo (what gsub would have erased)" do
      supplied = { neighborhood: "input syntax" }
      body     = refusal(%(PG::InvalidTextRepresentation: invalid input syntax for type uuid; ) +
                         %(neighborhood "input syntax" is not one this aggregator serves))

      expect(described_class.leak(body, ["invalid input syntax"], supplied: supplied))
        .to eq("invalid input syntax")

      naive = JSON.generate(body).gsub("input syntax", "")
      expect(naive.include?("invalid input syntax")).to be(false) # the false negative, demonstrated
    end

    it "still finds a DIFFERENT needle the app produced beside the echoed one" do
      supplied = { neighborhood: "PG::" }
      body     = refusal(%(invalid input syntax for type uuid; neighborhood "PG::" is not one this aggregator serves))

      result = described_class.scan(body, NEEDLES, supplied: supplied)
      expect(result.leak).to eq("invalid input syntax")
      expect(result.echoed).to eq(["PG::"])
    end

    # THE RESIDUAL LIMIT, PINNED RATHER THAN CLAIMED. When the probe supplies a
    # needle VERBATIM, every occurrence of that needle looks echoed, including
    # one the app really did produce — nothing about the bytes distinguishes
    # "you sent me this" from "I said this", and no content-only oracle can.
    # This example exists so the limit is a measured, executable fact rather
    # than a sentence in a comment: the needle is not reported as a leak, it IS
    # reported as discounted, and `note` puts that in front of a human. The
    # protection against it is the example above — a real leak is essentially
    # never a lone needle with nothing else of the runtime's around it.
    it "cannot separate an echoed needle from an identical one the app produced" do
      supplied = { neighborhood: "PG::" }
      body     = refusal(%(PG::UndefinedColumn; neighborhood "PG::" is not one this aggregator serves))

      result = described_class.scan(body, ["PG::"], supplied: supplied)
      expect(result.leak).to be_nil
      expect(result.echoed).to eq(["PG::"])
      expect(result.note).to include("PG::")
    end
  end

  # ── Shape coverage: the four spellings a demo may echo a value in ───────────

  describe "the spellings an echo can take" do
    it "covers a bare interpolation (#{'#{value}'})" do
      body = refusal("invalid date: PG::22P02 — use the YYYY-MM-DD from an availability row")

      expect(described_class.leak(body, NEEDLES, supplied: { date: "PG::22P02" })).to be_nil
    end

    it "covers an inspected interpolation (#{'#{value.inspect}'})" do
      body = refusal(%(booking_id "PG::22P02" is not a uuid))

      expect(described_class.leak(body, NEEDLES, supplied: { booking_id: "PG::22P02" })).to be_nil
    end

    it "covers a leaf inside a container the probe sent whole" do
      cart = { items: [{ "sku" => "TypeError", "qty" => 1 }] }
      body = refusal(%(unknown sku(s): TypeError))

      expect(described_class.leak(body, NEEDLES, supplied: cart)).to be_nil
    end

    it "covers the container's own inspected spelling" do
      item = { sku: "TypeError", qty: 1 }
      body = refusal("each item must be a {sku, qty} object — got #{item.class} (#{item.inspect})")

      expect(described_class.leak(body, NEEDLES, supplied: { items: [item] })).to be_nil
    end

    it "handles non-string probe values without raising" do
      [true, false, nil, 1.5, 20_260_826, [], {}, [1], { "a" => 1 }].each do |value|
        expect { described_class.scan(refusal("no leak here"), NEEDLES, supplied: { arg: value }) }
          .not_to raise_error
      end
    end
  end

  # ── Degradation is towards the LOUD answer, never the quiet one ─────────────

  describe "a beat that declares nothing" do
    it "behaves exactly as the pre-fix oracle did" do
      junk = "PG::22P02"
      body = refusal(%(neighborhood #{junk.inspect} is not one this aggregator serves))

      expect(described_class.leak(body, NEEDLES)).to eq(pre_fix_oracle(body))
    end
  end

  # ── The bodies these beats actually meet ────────────────────────────────────

  describe "input shapes" do
    it "accepts a bare Array body (a successful query answers one)" do
      expect(described_class.leak([{ "id" => 1 }], NEEDLES, supplied: { limit: 1 })).to be_nil
    end

    it "accepts an already-serialized String body" do
      expect(described_class.leak(%({"detail":"PG::"}), NEEDLES)).to eq("PG::")
    end

    it "reports no leak for an empty body" do
      expect(described_class.scan({}, NEEDLES, supplied: nil).leak?).to be(false)
    end
  end

  # ── The strict containment rule ─────────────────────────────────────────────

  it "does not let two adjacent echoes cover a needle neither of them contains" do
    # "PG" and "::" are two separate supplied values; the union of their spans
    # covers "PG::" but no SINGLE span does, so the needle is still a leak.
    body = refusal("PG::")

    expect(described_class.leak(body, ["PG::"], supplied: %w[PG ::])).to eq("PG::")
  end
end
