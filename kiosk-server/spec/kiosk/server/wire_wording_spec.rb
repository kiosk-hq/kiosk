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

# THE CLASS THE TWO SENTENCES ABOVE ARE ONE INSTANCE OF (K-1307).
#
# K-465 fixed the sites it found; K-1294 fixed five more; the pass that filed
# K-1307 found three more by grepping `.message` rather than by re-reading
# either row. A fourth recurrence is the default outcome unless the CLASS is
# held by something, so the rule below is about a SHAPE and not about a
# sentence:
#
#   AN EXCEPTION MESSAGE THIS REPOSITORY DOES NOT OWN MAY NOT REACH THE
#   CONSTRUCTOR OF A WIRE ERROR.
#
# "Wire error" is asked of Ruby rather than listed here: a class is in scope
# when it descends from `Kiosk::Server::Errors::Base`, because `Base#to_problem`
# copies its `message` into the problem document's `detail` and nothing between
# there and the socket redacts it. `Errors::ConfigurationError` is therefore
# NOT in scope and its `#{e.message}` is not an offence — it is a bare
# StandardError with no code, no status and no `to_problem`, raised while an
# operator's own configuration is being read. The day someone gives it one it
# enters scope by itself, with nothing here to edit.
#
# "Does not own" is asked of the RESCUE rather than of an allowlist: the
# message is permitted when the variable it is read from was bound by a
# `rescue` whose every named class sits under `Kiosk::`. Our adapters raise our
# own exceptions carrying sentences we wrote and version — the PSP-agnostic
# `Kiosk::PaymentProviders::PaymentFailed` the pay path re-raises is the live
# instance — and banning those would only push the same text through a
# laundering builder. Everything else (`JSON::ParserError`, `JWT::DecodeError`,
# `OpenSSL::PKey::PKeyError`, `Rack::BadRequest`, a bare `StandardError`) is
# some other library's wording: it moves when that dependency is upgraded and,
# on the paths reachable before any credential is presented, it can echo the
# caller's own bytes straight back out. A bare `rescue => e` names nothing, so
# it is foreign too.
#
# TWO CONSTRUCTIONS, NOT ONE, AND THE SECOND WAS ADDED BY THE ROUTE THIS
# SWEEP'S OWN SCOPE NOTE SAID IT COULD NOT SEE (K-1310).
#
# The note used to read «a foreign message reaching the wire by a route that is
# not an `Errors` constructor — `HandlerMixin#kiosk_rescue_to_wire` renders
# `message: exception.message` into the sub-dispatch envelope and
# `HandlerDispatch#error_message` re-wraps that as the wire `detail`». That was
# TRUE, it was written honestly, and it was still a hole: a scope note that
# names a live leak documents the leak instead of holding it, and the leak was
# live — actionpack's «param is missing or the value is empty or invalid: sku»
# on a 400, MEASURED at head the day the note was read back.
#
# So `render` is the second construction. Every `render` in `kiosk-server/lib`
# is a controller answering a caller, and the sub-dispatch envelope is a wire
# error by a shorter road: {HandlerDispatch#decode} turns a non-2xx render into
# an {Errors::Base} and its `message` into the problem document's `detail`. The
# ownership rule is identical, so the same walker answers both — and it answers
# `render` even when the render carries no `error` key at all, because a body
# is a body.
#
# WHAT THIS SWEEP STILL DOES NOT SEE, said out loud rather than left to be
# found — and this list is a statement about the DETECTOR, never a licence for
# the paths it names:
#
#   * a message laundered through a local first (`detail = e.message` a line
#     up, `Errors::BadRequest.new(detail)` a line down);
#   * `#{e.class}`, which is a class NAME and not a sentence: it cannot carry
#     the caller's bytes and does not move with a dependency's wording. Two
#     500 paths keep it deliberately, with the message beside it in the log.
module KioskWireErrorSweep
  module_function

  Offence = Struct.new(:path, :line, :source, :variable)

  def const_lookup(name)
    Object.const_get(name, false)
  rescue ::NameError, ::TypeError, ::LoadError
    nil
  end

  # What an `Errors::X` / bare `X` / fully-qualified spelling names, resolved
  # the way the `module Kiosk; module Server` nesting of the file it was read
  # from would resolve it.
  def resolve(path)
    joined = path.join("::")
    ["Kiosk::Server::Errors::#{joined}", "Kiosk::Server::#{joined}", joined].each do |candidate|
      found = const_lookup(candidate)
      return found if found
    end
    nil
  end

  # In scope: everything whose `message` can become a problem document's
  # `detail` — the error classes themselves, and the `Errors` module, whose
  # builders return them.
  def in_scope?(const)
    return false if const.nil?
    return true if const.equal?(Kiosk::Server::Errors)

    # `<=` answers nil, not false, for two unrelated classes; a predicate
    # that can answer nil is a predicate whose negative nobody can assert.
    const.is_a?(Class) && !(const <= Kiosk::Server::Errors::Base).nil? &&
      const <= Kiosk::Server::Errors::Base
  end

  def const_path(node)
    return nil unless node.is_a?(Array)

    case node[0]
    when :var_ref, :const_ref, :top_const_ref
      inner = node[1]
      inner.is_a?(Array) && inner[0] == :@const ? [inner[1]] : nil
    when :@const
      [node[1]]
    when :const_path_ref
      left  = const_path(node[1])
      right = node[2]
      left && right.is_a?(Array) && right[0] == :@const ? left + [right[1]] : nil
    end
  end

  # Whole paths only: `::JWT::MissingRequiredClaim` is one answer, not two.
  def maximal_const_paths(node, acc = [])
    return acc unless node.is_a?(Array)

    path = const_path(node)
    return acc << path if path

    node.each { |child| maximal_const_paths(child, acc) if child.is_a?(Array) }
    acc
  end

  def owned_rescue?(exception_node)
    paths = maximal_const_paths(exception_node)
    !paths.empty? && paths.all? { |path| path.first == "Kiosk" }
  end

  # Every `<receiver>.message` in a subtree, with the line, the receiver's name
  # when it is a plain local, and what the enclosing rescues bound it to. An
  # unknown receiver stays unknown, and unknown is treated as foreign.
  def message_sends(node, env, acc = [])
    return acc unless node.is_a?(Array)

    if node[0] == :call
      receiver = node[1]
      meth     = node[3]
      if meth.is_a?(Array) && meth[0] == :@ident && meth[1] == "message"
        name = receiver.is_a?(Array) && receiver[0] == :var_ref &&
               receiver[1].is_a?(Array) && receiver[1][0] == :@ident ? receiver[1][1] : nil
        acc << [meth[2][0], name, env[name]]
      end
    end

    node.each { |child| message_sends(child, env, acc) if child.is_a?(Array) }
    acc
  end

  # The two-and-a-half spellings that build a wire error: `Errors::X.new(…)`
  # and `Errors.builder(…)`; `raise Errors::X, "…"`; and the same raise with
  # parentheses.
  def constructor_arguments(node)
    if node[0] == :method_add_arg && node[1].is_a?(Array)
      head = node[1]
      if head[0] == :call
        target = const_path(head[1])
        meth   = head[3]
        const  = target && resolve(target)
        if meth.is_a?(Array) && meth[0] == :@ident && in_scope?(const) &&
           (meth[1] == "new" || const.equal?(Kiosk::Server::Errors))
          return node[2]
        end
      elsif head[0] == :fcall && head[1].is_a?(Array) && head[1][1] == "raise"
        return node[2] if raised_wire_error?(node[2])
      end
    end

    if node[0] == :command || node[0] == :command_call
      ident = node[0] == :command ? node[1] : node[3]
      if ident.is_a?(Array) && ident[0] == :@ident && ident[1] == "raise"
        args = node.last
        return args if raised_wire_error?(args)
      end
    end

    nil
  end

  # The second construction (K-1310): `render …` — parenthesised or not. No
  # receiver, so it is an `fcall`/`command` on the bare name, which is what a
  # controller writes and what {HandlerMixin} wrote the leak in. The BODY is
  # not inspected for an `error` key: `render json: { message: e.message }`
  # with no envelope around it would reach a caller just as directly, and a
  # detector that required the envelope would be checking the shape of a leak
  # rather than the leak.
  def render_arguments(node)
    if node[0] == :method_add_arg && node[1].is_a?(Array) && node[1][0] == :fcall
      name = node[1][1]
      return node[2] if name.is_a?(Array) && name[0] == :@ident && name[1] == "render"
    end

    if node[0] == :command
      ident = node[1]
      return node.last if ident.is_a?(Array) && ident[0] == :@ident && ident[1] == "render"
    end

    nil
  end

  def raised_wire_error?(args)
    return false unless args.is_a?(Array)

    list  = args[0] == :arg_paren ? args[1] : args
    list  = list[1] if list.is_a?(Array) && list[0] == :args_add_block
    first = list.is_a?(Array) ? list[0] : nil
    path  = first.is_a?(Array) ? const_path(first) : nil
    !path.nil? && in_scope?(resolve(path))
  end

  def walk(node, env, result, lines, path)
    return unless node.is_a?(Array)

    if node[0] == :rescue
      _, exception_node, var, body, following = node
      name = var.is_a?(Array) && var[0] == :var_field && var[1].is_a?(Array) &&
             var[1][0] == :@ident ? var[1][1] : nil
      inner = name ? env.merge(name => (owned_rescue?(exception_node) ? :owned : :foreign)) : env
      walk(exception_node, env, result, lines, path)
      walk(body, inner, result, lines, path)
      walk(following, env, result, lines, path)
      return
    end

    args = constructor_arguments(node)
    if args
      result[:sites] += 1
      collect(args, env, result, lines, path)
    end

    rendered = render_arguments(node)
    if rendered
      result[:renders] += 1
      collect(rendered, env, result, lines, path)
    end

    node.each { |child| walk(child, env, result, lines, path) if child.is_a?(Array) }
  end

  def collect(args, env, result, lines, path)
    message_sends(args, env).each do |(line, name, ownership)|
      found = Offence.new(path, line, lines[line - 1].to_s.strip, name)
      (ownership == :owned ? result[:owned] : result[:offences]) << found
    end
  end

  def scan(source, path: "(fixture)")
    tree = Ripper.sexp(source)
    raise ArgumentError, "#{path} does not parse" if tree.nil?

    result = { sites: 0, renders: 0, offences: [], owned: [] }
    walk(tree, {}, result, source.lines, path)
    result[:offences].uniq!
    result[:owned].uniq!
    result
  end
end

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

  # ── the third sentence: a Rails-native raise (K-1310) ─────────────────────
  describe "Kiosk::Server::Errors.rescued_wire" do
    it "words the refusal itself and names the verb, so nothing of the exception travels" do
      built = Kiosk::Server::Errors.rescued_wire("bad_request", verb: "strict")
      expect(built[:code]).to eq("bad_request")
      expect(built[:message]).to eq('verb "strict" rejected the request as malformed')
      expect(built[:hint]).to eq(Kiosk::Server::Errors::RESCUED_HINTS.fetch("bad_request"))
    end

    it "says `this verb` when the dispatch name is unknown, rather than rendering nil" do
      expect(Kiosk::Server::Errors.rescued_wire("not_found")[:message])
        .to eq("this verb found no such record")
      expect(Kiosk::Server::Errors.rescued_wire("not_found", verb: "")[:message])
        .to eq("this verb found no such record")
    end

    # THE TABLE IS THE CONTRACT. `kiosk_rescue_to_wire` reaches this builder for
    # whatever code {STATUS_CODES} decides, so a code that table can produce and
    # this one cannot word would be a `KeyError` at request time — a 500 in
    # place of the 4xx the seam had already chosen.
    it "words every code the rescue seam can decide, and invents none" do
      reachable = Kiosk::Server::Errors::STATUS_CODES.values.uniq.sort
      expect(Kiosk::Server::Errors::RESCUED_DETAILS.keys.sort).to eq(reachable)
      expect(Kiosk::Server::Errors::RESCUED_HINTS.keys.sort).to eq(reachable)
    end

    it "carries no Ruby, no library and no exception wording in any entry" do
      Kiosk::Server::Errors::STATUS_CODES.values.uniq.each do |code|
        built = Kiosk::Server::Errors.rescued_wire(code, verb: "v")
        expect(built[:message]).not_to be_empty
        expect(built[:hint]).not_to be_empty
        RUBY_LEAKS.each do |leak|
          expect(built[:message]).not_to match(leak)
          expect(built[:hint]).not_to match(leak)
        end
      end
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

    # LITERAL OR INTERPOLATED, and the difference is why this arm was 15/0 with
    # the defect in front of it (K-1306). It used to skip every line without a
    # `#{`, so it hunted the SPLICE and was blind to the other way of breaking
    # the same rule: `kyc_attestation_controller.rb` simply typed the sentence
    # out — `raise Errors::BadRequest.new("missing field: kyc_jws")` — which is
    # the correct sentence today and a second place for it to drift from
    # tomorrow, while `errors.rb` two files away declared the sentences "BUILT
    # HERE AND NOWHERE ELSE". A declaration nothing can falsify is the shape
    # this whole file exists to stop, so the rule is now what the declaration
    # says: outside errors.rb these bytes do not appear at all.
    it "builds `missing field:` and `invalid JSON body` nowhere but errors.rb, literal or interpolated" do
      offenders = sources.flat_map do |path|
        rel = path.delete_prefix("#{gem_root}/")
        next [] if rel == BUILDER_FILE

        code_without_comments(path).lines.each_with_index.filter_map do |line, idx|
          next unless HOUSE_SENTENCES.any? { |s| line.include?(s) }

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

  # ── the K-1307 sweep: no FOREIGN message reaches a wire error ─────────────
  #
  # The rule, its scope line and the two things it deliberately cannot see are
  # written out on {KioskWireErrorSweep} at the top of this file.
  describe "kiosk-server's wire errors" do
    # Measured at head when this arm was written: 113 constructor sites and one
    # message excused by ownership. The floor is set well below the count so
    # ordinary editing does not move it, and well above zero so a sweep that has
    # stopped recognising constructors cannot pass by finding nothing to judge.
    MINIMUM_CONSTRUCTOR_SITES = 80
    # Measured at head when the `render` arm was added (K-1310): 31 render
    # sites (114 constructor sites beside them). Same reasoning as the floor above — well
    # below the count so ordinary editing does not move it, well above zero so
    # a walker that has stopped recognising `render` cannot pass by judging
    # nothing.
    MINIMUM_RENDER_SITES = 10

    let(:gem_root) { File.expand_path("../../..", __dir__) }
    let(:sources)  { Dir.glob("#{gem_root}/lib/**/*.rb").sort }

    let(:census) do
      sources.each_with_object({ sites: 0, renders: 0, offences: [], owned: [] }) do |path, acc|
        found = KioskWireErrorSweep.scan(File.read(path), path: path.delete_prefix("#{gem_root}/"))
        acc[:sites]   += found[:sites]
        acc[:renders] += found[:renders]
        acc[:offences].concat(found[:offences])
        acc[:owned].concat(found[:owned])
      end
    end

    it "never lets an exception message this repository does not own reach a wire error" do
      expect(census[:offences].map { |o| "#{o.path}:#{o.line}: #{o.source}" }).to be_empty
    end

    # ── vacuity ────────────────────────────────────────────────────────────
    #
    # The failure this workspace repeats is a rule that matches NOTHING while
    # reading as coverage: a pattern that required a word no live sentence used
    # guarded nothing for its entire existence, and nothing said so. Three arms,
    # one per way this sweep could quietly stop seeing.

    it "resolves the constants it keys on, and draws its scope line where it says it does (vacuity)" do
      expect(KioskWireErrorSweep.resolve(%w[Errors BadRequest]))
        .to be(Kiosk::Server::Errors::BadRequest)
      expect(KioskWireErrorSweep.resolve(%w[Errors])).to be(Kiosk::Server::Errors)
      expect(KioskWireErrorSweep.in_scope?(Kiosk::Server::Errors::BadRequest)).to be(true)
      expect(KioskWireErrorSweep.in_scope?(Kiosk::Server::Errors)).to be(true)
      # The boundary this sweep documents: ConfigurationError has no `to_problem`
      # and never becomes a document, so its message is not the wire's business.
      expect(KioskWireErrorSweep.in_scope?(Kiosk::Server::Errors::ConfigurationError)).to be(false)
    end

    it "still recognises wire-error constructors in the shipped source (vacuity)" do
      expect(census[:sites]).to be >= MINIMUM_CONSTRUCTOR_SITES,
        "the sweep found #{census[:sites]} constructor sites in lib/ — it has stopped " \
        "recognising them, and an empty offence list means nothing until it does"
    end

    it "still recognises `render` sites in the shipped source (vacuity)" do
      expect(census[:renders]).to be >= MINIMUM_RENDER_SITES,
        "the sweep found #{census[:renders]} render sites in lib/ — the K-1310 arm has " \
        "stopped recognising them, and it is the arm that covers the sub-dispatch envelope"
    end

    it "still finds one of OUR OWN messages reaching a wire error, or the carve-out guards nothing (vacuity)" do
      expect(census[:owned]).not_to be_empty,
        "no shipped site re-raises a Kiosk-owned exception's message any more — the ownership " \
        "carve-out now excuses nothing that exists, so re-aim it or delete it"
    end

    # ── self-test: the detector reports what it says it reports ─────────────

    it "reports a foreign message spliced into a wire error (self-test)" do
      source = <<~'RUBY'
        module Kiosk
          module Server
            module Probe
              def self.call
                JSON.parse("x")
              rescue JSON::ParserError => e
                raise Errors::BadRequest.new("malformed: #{e.message}")
              end
            end
          end
        end
      RUBY
      found = KioskWireErrorSweep.scan(source, path: "(self-test)")
      expect(found[:offences].size).to eq(1)
      expect(found[:offences].first.line).to eq(7)
      expect(found[:owned]).to be_empty
    end

    it "reports one spliced into a HINT, which reaches the wire too (self-test)" do
      source = <<~'RUBY'
        rescue Rack::BadRequest => e
          raise Errors::BadRequest.new("undecodable", hint: "rack said #{e.message}")
        end
      RUBY
      expect(KioskWireErrorSweep.scan("begin\n#{source}", path: "(self-test)")[:offences].size).to eq(1)
    end

    it "reports the comma form, which carries no `.new` to key on (self-test)" do
      source = <<~'RUBY'
        begin
          nil
        rescue StandardError => e
          raise Errors::Unauthenticated, "proof rejected: #{e.message}"
        end
      RUBY
      expect(KioskWireErrorSweep.scan(source, path: "(self-test)")[:offences].size).to eq(1)
    end

    it "excuses a Kiosk-owned message, and ONLY a Kiosk-owned one (self-test)" do
      ours = <<~'RUBY'
        begin
          nil
        rescue Kiosk::PaymentProviders::PaymentFailed => e
          raise Errors::PaymentFailed.new(e.message, hint: "retry")
        end
      RUBY
      theirs = ours.sub("Kiosk::PaymentProviders::PaymentFailed", "StandardError")

      expect(KioskWireErrorSweep.scan(ours, path: "(self-test)")[:offences]).to be_empty
      expect(KioskWireErrorSweep.scan(ours, path: "(self-test)")[:owned].size).to eq(1)
      expect(KioskWireErrorSweep.scan(theirs, path: "(self-test)")[:offences].size).to eq(1)
    end

    it "treats a bare `rescue => e`, which names nothing, as foreign (self-test)" do
      source = <<~'RUBY'
        begin
          nil
        rescue => e
          raise Errors::BadRequest.new("no: #{e.message}")
        end
      RUBY
      expect(KioskWireErrorSweep.scan(source, path: "(self-test)")[:offences].size).to eq(1)
    end

    # ── the K-1310 arm: the sub-dispatch envelope is a wire error too ──────

    it "reports a foreign message rendered into the sub-dispatch envelope (self-test)" do
      # The leak verbatim, as `handler_mixin.rb` carried it: no `Errors`
      # constructor anywhere on the line, which is exactly why the old sweep's
      # scope note had to name this route instead of holding it.
      source = <<~'RUBY'
        begin
          nil
        rescue StandardError => exception
          render json: {
            ok:    false,
            error: { code: code, message: exception.message },
          }, status: 400
        end
      RUBY
      found = KioskWireErrorSweep.scan(source, path: "(self-test)")
      expect(found[:offences].size).to eq(1)
      expect(found[:renders]).to eq(1)
    end

    it "reports one rendered by a method PARAMETER, which no rescue owns (self-test)" do
      # `rescue_from(StandardError, with: :kiosk_rescue_to_wire)` hands the
      # exception in as an argument, so there is no `rescue` in the method at
      # all — and an unknown receiver is foreign, which is what makes this
      # shape visible rather than excused.
      source = <<~'RUBY'
        def kiosk_rescue_to_wire(exception)
          render(json: { error: { message: exception.message } }, status: 400)
        end
      RUBY
      expect(KioskWireErrorSweep.scan(source, path: "(self-test)")[:offences].size).to eq(1)
    end

    it "excuses a Kiosk-owned message in a render, on the same terms (self-test)" do
      source = <<~'RUBY'
        begin
          nil
        rescue Kiosk::PaymentProviders::PaymentFailed => e
          render json: { error: { message: e.message } }, status: 402
        end
      RUBY
      found = KioskWireErrorSweep.scan(source, path: "(self-test)")
      expect(found[:offences]).to be_empty
      expect(found[:owned].size).to eq(1)
    end

    it "leaves a render that carries no exception message alone (self-test)" do
      source = <<~'RUBY'
        render json: { ok: false, error: Errors.rescued_wire(code, verb: name) }, status: 400
      RUBY
      found = KioskWireErrorSweep.scan(source, path: "(self-test)")
      expect(found[:offences]).to be_empty
      expect(found[:renders]).to eq(1)
    end

    it "leaves a non-wire error alone, which is where its scope line falls (self-test)" do
      source = <<~'RUBY'
        begin
          nil
        rescue NameError => e
          raise Errors::ConfigurationError, "does not resolve (#{e.class}: #{e.message})"
        end
      RUBY
      found = KioskWireErrorSweep.scan(source, path: "(self-test)")
      expect(found[:offences]).to be_empty
      expect(found[:sites]).to eq(0)
    end
  end
end
