# frozen_string_literal: true

require "spec_helper"
require "tempfile"

# K-1713. THE ENGINE'S ERROR VOCABULARY IS THIS GEM'S STUB VOCABULARY, AND
# NOTHING USED TO COMPARE THE TWO.
#
# `spec_helper.rb` carried seventeen `code` to status rows typed out by hand
# under a comment naming `Kiosk::Server::Errors::CODES` as their source, plus a
# copy of that file's `STATUS_CODES`. They were byte-identical to the engine on
# the day the row was written, which is exactly why it was `minor` and exactly
# why it could rot: every verdict this harness reaches branches on `code`, the
# specs that prove the branching stub the wire FROM those rows, and a code the
# engine adds, re-statuses or drops leaves this suite green while it stubs an
# answer the server can no longer send.
#
# The repair is that there is no copy left — `spec_helper.rb` PARSES both tables
# out of the sibling's source at load time. This file is what keeps that
# derivation honest, because a parser is the new place the rot can hide: a
# regex that quietly matches less than it should hands back a smaller table that
# still looks like a vocabulary.
#
# WHAT IS ASSERTED, and each arm is here because it can fail on its own:
#
#   V1  the parse is not vacuous — shapes and sizes, on both tables
#   V2  the two tables agree with each other: a bare status may only default to
#       a code the closed vocabulary carries
#   V3  the widening over the engine's bare-status table is OURS and is exactly
#       the crashing-origin statuses — the prose that stood here before said it
#       widened `STATUS_CODES` with «422, 500, 502 and 503», and 422 is in the
#       engine's own table, so the sentence named a widening that was not one
#   V4  every code this gem's own specs stub is in the derived vocabulary. This
#       is the arm that reddens when the engine drops a code the suite still
#       names, which is the motivating defect
#   V5  the parser refuses what it cannot read, rather than returning a short
#       table. Three fixtures, one per raise
RSpec.describe "the engine error vocabulary this suite stubs from" do
  describe "V1 the parse is not vacuous" do
    it "reads the closed vocabulary as code strings onto HTTP error statuses" do
      expect(PROBLEM_STATUS.size).to be > 10
      expect(PROBLEM_STATUS.keys).to all(be_a(String))
      expect(PROBLEM_STATUS.values).to all(be_between(400, 599))
    end

    it "reads the bare-status table as statuses onto code strings" do
      expect(ENGINE_STATUS_CODES.size).to be > 5
      expect(ENGINE_STATUS_CODES.keys).to all(be_between(400, 599))
      expect(ENGINE_STATUS_CODES.values).to all(be_a(String))
    end
  end

  describe "V2 the two engine tables agree with each other" do
    it "defaults every bare status to a code the closed vocabulary carries" do
      expect(ENGINE_STATUS_CODES.values.uniq - PROBLEM_STATUS.keys).to be_empty
    end
  end

  describe "V3 the widening is ours and is only the crashing-origin statuses" do
    it "adds exactly the statuses a crashing origin renders" do
      expect(STATUS_DEFAULT_CODE.keys - ENGINE_STATUS_CODES.keys)
        .to match_array(CRASHING_ORIGIN_STATUS_CODES.keys)
    end

    it "overrides nothing the engine already decides" do
      expect(CRASHING_ORIGIN_STATUS_CODES.keys & ENGINE_STATUS_CODES.keys).to be_empty
      ENGINE_STATUS_CODES.each do |status, code|
        expect(STATUS_DEFAULT_CODE[status]).to eq(code)
      end
    end
  end

  describe "V4 every code this suite stubs is one the engine can still emit" do
    # Read off this gem's own spec corpus rather than listed here: a list would
    # be the third hand-kept copy of the same vocabulary.
    stubbed = Dir.glob(File.join(__dir__, "**", "*.rb")).sort.flat_map do |file|
      File.read(file)
          .scan(/\bproblem(?:_return)?\(\s*(?::([a-z_]+)|"([a-z_]+)")/)
          .map { |symbol, string| symbol || string }
    end.uniq.sort

    it "found codes to check at all (the arm below is not vacuous)" do
      expect(stubbed.size).to be > 5
    end

    stubbed.each do |code|
      it "stubs `#{code}`, which the engine's vocabulary carries" do
        expect(PROBLEM_STATUS).to have_key(code)
      end
    end
  end

  describe "V5 the parser refuses what it cannot read" do
    def parsing(source)
      Tempfile.create(["errors", ".rb"]) do |file|
        file.write(source)
        file.flush
        yield file.path
      end
    end

    it "raises when the named table is not a frozen literal in the file" do
      parsing("module Kiosk\nend\n") do |path|
        expect { kiosk_engine_table("CODES", path) }
          .to raise_error(/CODES is not a frozen literal table/)
      end
    end

    it "raises on an empty table rather than returning one" do
      parsing("      CODES = {\n      }.freeze\n") do |path|
        expect { kiosk_engine_table("CODES", path) }
          .to raise_error(/CODES parsed to nothing/)
      end
    end

    it "raises on a line it cannot read rather than skipping it" do
      source = <<~SOURCE
              CODES = {
                "bad_request" => 400,
                "computed"    => SOME_CONSTANT,
              }.freeze
      SOURCE
      parsing(source) do |path|
        expect { kiosk_engine_table("CODES", path) }
          .to raise_error(/CODES has 1 line\(s\) this parser cannot read/)
      end
    end

    it "reads a well-formed table of both key shapes" do
      source = <<~SOURCE
              CODES = {
                "bad_request" => 400,
                404 => "not_found",
              }.freeze
      SOURCE
      parsing(source) do |path|
        expect(kiosk_engine_table("CODES", path))
          .to eq("bad_request" => 400, 404 => "not_found")
      end
    end
  end
end
