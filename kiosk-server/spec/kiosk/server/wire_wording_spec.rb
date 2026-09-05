# frozen_string_literal: true

# THE MALFORMED-REQUEST SENTENCES THE ENGINE PUTS ON THE WIRE (K-1294).
#
# The engine used to build both of them by splicing a Ruby exception's
# `message` into the problem document's `detail`. MEASURED live against the
# deployed fleet on 2026-09-05, `POST /kiosk/auth/register` with `{}` answered
#
#   "detail":"missing field: key not found: :public_key"
#
# — `KeyError#message` verbatim, Ruby symbol and all, on the FIRST call any
# assistant makes — and a body that was not JSON answered
#
#   "detail":"invalid JSON body: unexpected token 'notjson' at line 1 column 1"
#
# which is the json gem's wording rather than this protocol's.
#
# `missing field: <name>` is the HOUSE SENTENCE: the demos answer an absent
# argument with it, bin/check-demo-copies calls it "the one an assistant's
# error handling matches on" and holds three demos to it — but that rule's file
# set is `kiosk-demo-*`, so the engine, which is the one place a FOURTH wording
# was being emitted, was outside every mechanism in the tree.
#
# Two arms, and they answer different questions. The behavioural ones pin what
# each SITE answers today; the source sweep at the bottom is what stops the
# next site being written the old way, because a spec can only assert about
# endpoints somebody remembered to dispatch.
#
# Dispatch via `ActionController::Metal.action(...)` — a plain Rack app, no
# Rails host and no database.

require "rack/mock"
require "ripper"
require "json"

RSpec.describe "the malformed-request sentences on the wire" do
  let(:user_id) { "11111111-1111-1111-1111-111111111111" }

  def wire_user_idp(identity)
    idp = Class.new do
      def initialize(identity) = @identity = identity
      def verify(_request) = @identity
    end
    Kiosk.configure { |c| c.user_idp = idp.new(identity) }
  end

  before do
    Kiosk.configure do |c|
      c.issuer      = "https://provider.example"
      c.signing_key = Kiosk::Server::SigningKey.generate
      c.roles       = %i[customer]
    end
  end

  def post(action, raw_body)
    env = Rack::MockRequest.env_for(
      "https://provider.example/kiosk/auth/#{action}",
      method: "POST", input: raw_body, "CONTENT_TYPE" => "application/json",
    )
    status, headers, body = Kiosk::Server::AuthController.action(action).call(env)
    raw = +""
    body.each { |chunk| raw << chunk }
    [status, headers, raw.empty? ? {} : JSON.parse(raw, symbolize_names: true)]
  end

  # Every assertion below reads the SAME three things, because a detail that is
  # right while the document around it is not would still not be usable: the
  # media type that makes this a problem document, the flat `code` an assistant
  # branches on, and the exact `detail`.
  def expect_detail(status, headers, body, detail)
    expect(status).to eq(400)
    expect(headers["Content-Type"]).to include("application/problem+json")
    expect(body[:code]).to eq("bad_request")
    expect(body[:detail]).to eq(detail)
  end

  # The Ruby-side leaks, named rather than implied: `KeyError#message` reads
  # "key not found: :public_key", the json gem's reads "unexpected token …",
  # and an object that reached `to_s` by accident reads "#<…>". None of the
  # three may appear in a detail whatever else is true of it.
  RUBY_LEAKS = [/key not found/, /unexpected token/, /#</].freeze

  def expect_no_ruby(body)
    RUBY_LEAKS.each { |leak| expect(body[:detail]).not_to match(leak) }
  end

  # ── site 1 of 4: POST /auth/register, the first call an assistant makes ────
  describe "POST /kiosk/auth/register" do
    it "names the absent field and not the Ruby exception when public_key is omitted" do
      status, headers, body = post(:register, JSON.generate(signed: "x"))
      expect_detail(status, headers, body, "missing field: public_key")
      expect_no_ruby(body)
    end

    it "names the absent field when signed is omitted" do
      status, headers, body = post(:register, JSON.generate(public_key: "x"))
      expect_detail(status, headers, body, "missing field: signed")
      expect_no_ruby(body)
    end

    it "answers a body that is not JSON with this protocol's own sentence" do
      status, headers, body = post(:register, "notjson")
      expect_detail(status, headers, body, "invalid JSON body")
      expect_no_ruby(body)
      expect(body[:hint]).to eq(Kiosk::Server::Errors::MALFORMED_JSON_HINT)
    end
  end

  # ── site 2 of 4: POST /auth/login ─────────────────────────────────────────
  describe "POST /kiosk/auth/login" do
    it "names the absent field when signed is omitted" do
      status, headers, body = post(:login, JSON.generate(public_key: "x"))
      expect_detail(status, headers, body, "missing field: signed")
      expect_no_ruby(body)
    end
  end

  # ── site 3 of 4: POST /auth/claim, the register-shaped redeem ─────────────
  describe "POST /kiosk/auth/claim" do
    it "names the absent field when signed is omitted" do
      status, headers, body = post(:claim, JSON.generate(code: "c", public_key: "PEM"))
      expect_detail(status, headers, body, "missing field: signed")
      expect_no_ruby(body)
    end
  end

  # ── site 4 of 4: POST /auth/unlink, behind the human's own session ────────
  describe "POST /kiosk/auth/unlink" do
    it "names the absent field when agent_id is omitted" do
      wire_user_idp(build_identity(actor: "human", agent_id: nil, user_id: user_id))
      status, headers, body = post(:unlink, JSON.generate({}))
      expect_detail(status, headers, body, "missing field: agent_id")
      expect_no_ruby(body)
    end
  end

  # ── the two builders themselves ───────────────────────────────────────────
  describe "Kiosk::Server::Errors.missing_field" do
    it "names the KEY of a rescued KeyError, never its message" do
      err = begin
        {}.fetch(:public_key)
      rescue KeyError => e
        e
      end
      expect(err.message).to include("key not found")
      expect(Kiosk::Server::Errors.missing_field(err).message).to eq("missing field: public_key")
    end

    it "accepts a bare field name too, so a site with no exception can use it" do
      expect(Kiosk::Server::Errors.missing_field("agent_id").message).to eq("missing field: agent_id")
    end

    it "falls back to plain words — never to `message` — for a KeyError carrying no key" do
      err = begin
        raise KeyError, "key not found: :smuggled"
      rescue KeyError => e
        e
      end
      built = Kiosk::Server::Errors.missing_field(err)
      expect(built.message).to eq("request is missing a required field")
      expect(built.message).not_to include("smuggled")
    end
  end

  describe "Kiosk::Server::Errors.malformed_json" do
    it "is the whole detail, with the recovery sentence in the hint" do
      built = Kiosk::Server::Errors.malformed_json
      expect(built.message).to eq("invalid JSON body")
      expect(built.hint).to eq(Kiosk::Server::Errors::MALFORMED_JSON_HINT)
    end

    it "lets a site narrow the hint without touching the detail" do
      built = Kiosk::Server::Errors.malformed_json(hint: "a query's arguments are in the query string.")
      expect(built.message).to eq("invalid JSON body")
      expect(built.hint).to eq("a query's arguments are in the query string.")
    end
  end

  # ── the sweep: no site may build either sentence for itself ───────────────
  #
  # The behavioural arms above cover the endpoints somebody remembered to
  # dispatch, which is exactly how the fourth wording survived: the leak was on
  # register, and register had four specs about missing fields, none of which
  # read the sentence. So the class is closed structurally instead — outside
  # errors.rb, where the two builders live, either sentence may appear only as
  # a COMPLETE literal (`"missing field: kyc_jws"`); an interpolation there is
  # the splice this row is about, whatever it interpolates.
  #
  # Read from the code with comments stripped, via Ripper rather than a `^\s*#`
  # scan, so this file's own quotations of the bad strings — and errors.rb's —
  # are not evidence, while a `#` inside a string still is.
  describe "kiosk-server's source" do
    HOUSE_SENTENCES = ["missing field:", "invalid JSON body"].freeze
    BUILDER_FILE    = "lib/kiosk/server/errors.rb"

    def code_without_comments(path)
      Ripper.lex(File.read(path))
            .reject { |(_, type, _)| type == :on_comment || type == :on_embdoc || type == :on_embdoc_beg }
            .map { |(_, _, tok)| tok }
            .join
    end

    let(:gem_root) { File.expand_path("../../..", __dir__) }
    let(:sources)  { Dir.glob("#{gem_root}/lib/**/*.rb").sort }

    it "has sources to sweep and a builder file among them (vacuity)" do
      expect(sources).not_to be_empty
      expect(sources.map { |p| p.delete_prefix("#{gem_root}/") }).to include(BUILDER_FILE)
    end

    it "still contains both house sentences somewhere, or this sweep guards nothing (vacuity)" do
      HOUSE_SENTENCES.each do |sentence|
        expect(sources.any? { |p| code_without_comments(p).include?(sentence) })
          .to be(true), "no shipped line says #{sentence.inspect} any more — re-aim this sweep"
      end
    end

    it "builds `missing field:` and `invalid JSON body` nowhere but errors.rb, and never by interpolation" do
      offenders = sources.flat_map do |path|
        rel = path.delete_prefix("#{gem_root}/")
        next [] if rel == BUILDER_FILE

        code_without_comments(path).lines.each_with_index.filter_map do |line, idx|
          next unless HOUSE_SENTENCES.any? { |s| line.include?(s) }
          next unless line.include?('#{')

          "#{rel}:#{idx + 1}: #{line.strip}"
        end
      end
      expect(offenders).to be_empty
    end

    # The other half of the same rule, and the one the live leak actually
    # broke: errors.rb MAY interpolate — that is what a builder is — but it may
    # not interpolate an exception's message back in.
    it "never splices an exception's message into either sentence, errors.rb included" do
      offenders = sources.flat_map do |path|
        rel = path.delete_prefix("#{gem_root}/")
        code_without_comments(path).lines.each_with_index.filter_map do |line, idx|
          next unless HOUSE_SENTENCES.any? { |s| line.include?(s) }
          next unless line.match?(/\#\{[^}]*\bmessage\b/)

          "#{rel}:#{idx + 1}: #{line.strip}"
        end
      end
      expect(offenders).to be_empty
    end
  end
end
