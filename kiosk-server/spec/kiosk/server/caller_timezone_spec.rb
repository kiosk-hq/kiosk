# frozen_string_literal: true

require "kiosk/server/caller_timezone"

# ── THE CALLER'S DECLARED CLOCK ──────────────────────────────────────────────
#
# `Kiosk-Timezone` is the only thing on this wire that says which CALENDAR a
# bare `YYYY-MM-DD` argument was written on. Spec Section 3 point 8.
#
# What it is NOT is asserted here too, because that is the half a reader gets
# wrong: it never decides how an ANSWER is rendered. An answer is rendered at
# the place the service happens, and that zone is a property of the serviced
# RESOURCE, which is operator data this gem holds none of.
RSpec.describe Kiosk::Server::CallerTimezone do
  describe ".from_value" do
    it "resolves an IANA Area/Location name" do
      expect(described_class.from_value("Europe/Dublin").name).to eq("Europe/Dublin")
    end

    it "resolves the literal UTC" do
      expect(described_class.from_value("UTC").name).to eq("UTC")
    end

    # `Etc/GMT+2` is UTC MINUS two -- POSIX sign inversion. It is a legal IANA
    # identifier and the demos' gates use it to reproduce a day-behind caller on
    # demand, so it must resolve here or those gates cannot be written.
    it "resolves the Etc/GMT names the fleet's two-clock gates are driven at" do
      expect(described_class.from_value("Etc/GMT+2").name).to  eq("Etc/GMT+2")
      expect(described_class.from_value("Etc/GMT-11").name).to eq("Etc/GMT-11")
    end

    it "trims surrounding whitespace" do
      expect(described_class.from_value("  Europe/Dublin  ").name).to eq("Europe/Dublin")
    end

    it "answers nil when the caller declared nothing" do
      expect(described_class.from_value(nil)).to be_nil
      expect(described_class.from_value("")).to  be_nil
      expect(described_class.from_value("   ")).to be_nil
    end

    # THE REASON THE SHAPE IS A SHAPE AND NOT MERELY A LOOKUP: an offset cannot
    # carry a DST transition, so an operator holding one cannot say which side
    # of a boundary a FUTURE date falls on, and "the caller's tomorrow" stops
    # being answerable across one.
    it "refuses a UTC offset by name" do
      expect { described_class.from_value("+03:00") }
        .to raise_error(Kiosk::Server::Errors::BadRequest, /invalid Kiosk-Timezone/)
    end

    it "refuses a zone name nobody has" do
      expect { described_class.from_value("Mars/Olympus") }
        .to raise_error(Kiosk::Server::Errors::BadRequest, /Mars\/Olympus/)
    end

    # BOTH OF THESE RESOLVE IN ActiveSupport AND ARE STILL REFUSED. One declared
    # type admits one spelling (spec Section 8.1 rule 8's principle): an origin
    # that took three of them would leave an assistant guessing which spellings
    # THIS origin takes, which is the whole class the date rule already closed.
    it "refuses a Rails friendly name even though ActiveSupport resolves it" do
      expect(Time.find_zone("Central Time (US & Canada)")).not_to be_nil
      expect { described_class.from_value("Central Time (US & Canada)") }
        .to raise_error(Kiosk::Server::Errors::BadRequest)
    end

    it "refuses a single-word tz abbreviation even though ActiveSupport resolves it" do
      expect(Time.find_zone("EST")).not_to be_nil
      expect { described_class.from_value("EST") }
        .to raise_error(Kiosk::Server::Errors::BadRequest)
    end

    it "carries a hint naming what IS accepted" do
      described_class.from_value("nonsense")
    rescue Kiosk::Server::Errors::BadRequest => e
      expect(e.hint).to include("Area/Location")
      expect(e.hint).to include("UTC")
      expect(e.hint).to include("DST")
    end

    it "refuses with a 400" do
      expect(Kiosk::Server::Errors::BadRequest::HTTP_STATUS).to eq(400)
    end
  end

  describe ".from_env" do
    it "reads the Rack env key HTTP_KIOSK_TIMEZONE" do
      zone = described_class.from_env("HTTP_KIOSK_TIMEZONE" => "Australia/Sydney")
      expect(zone.name).to eq("Australia/Sydney")
    end

    it "answers nil for an env with no such header, and for no env at all" do
      expect(described_class.from_env({})).to be_nil
      expect(described_class.from_env(nil)).to be_nil
    end

    it "names the header the caller actually sent when it refuses" do
      expect { described_class.from_env("HTTP_KIOSK_TIMEZONE" => "+05:30") }
        .to raise_error(Kiosk::Server::Errors::BadRequest, /Kiosk-Timezone/)
    end
  end

  it "names the header with the protocol constant, so one spelling exists" do
    expect(described_class::HEADER).to eq(Kiosk::Protocol::HEADER_TIMEZONE)
    expect(described_class::HEADER).to eq("Kiosk-Timezone")
  end
end
