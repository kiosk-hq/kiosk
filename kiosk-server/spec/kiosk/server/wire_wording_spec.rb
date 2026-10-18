# frozen_string_literal: true

# The sentences the engine puts on the wire for a malformed request.
#
# A missing field reads `missing field: <name>`, the house sentence the demos
# use too. A body that is not JSON reads `invalid JSON body`. Neither carries a
# Ruby exception's message (`key not found: :public_key`) or a library's
# wording (`unexpected token …`).
#
# The behavioural examples pin what each endpoint answers. The source sweeps at
# the bottom stop the next site being written the wrong way, because an
# example can only assert about the endpoints it dispatches.
#
# Dispatch is via `ActionController::Metal.action(...)`: a plain Rack app, no
# Rails host and no database.

require 'rack/mock'
require 'ripper'
require 'json'

# Readers for Ripper s-expression nodes.
module KioskWireErrorNodes
  def type?(node, type) = node.is_a?(Array) && node[0] == type
  def ident?(node, name = nil) = type?(node, :@ident) && (name.nil? || node[1] == name)
  def const_token(node) = type?(node, :@const) ? node[1] : nil

  # The local variable name a `var_ref` or `var_field` node holds, or nil.
  def local_name(node, type)
    node[1][1] if type?(node, type) && ident?(node[1])
  end

  # The constant path a node spells, as an array of names, or nil.
  def const_path(node)
    return nil unless node.is_a?(Array)

    case node[0]
    when :var_ref, :const_ref, :top_const_ref then (name = const_token(node[1])) && [name]
    when :@const then [node[1]]
    when :const_path_ref then nested_const_path(node)
    end
  end

  def nested_const_path(node)
    left  = const_path(node[1])
    right = const_token(node[2])
    left && right ? left + [right] : nil
  end

  # Whole paths only: `::JWT::MissingRequiredClaim` is one answer, not two.
  def maximal_const_paths(node, acc = [])
    return acc unless node.is_a?(Array)

    path = const_path(node)
    return acc << path if path

    node.each { |child| maximal_const_paths(child, acc) }
    acc
  end

  # Every `<receiver>.message` in a subtree, as [line, receiver local name,
  # what the enclosing rescues bound that name to]. An unknown receiver stays
  # unknown, and unknown is treated as foreign.
  def message_sends(node, env, acc = [])
    return acc unless node.is_a?(Array)

    if node[0] == :call && ident?(node[3], 'message')
      name = local_name(node[1], :var_ref)
      acc << [node[3][2][0], name, env[name]]
    end
    node.each { |child| message_sends(child, env, acc) }
    acc
  end
end

# Which constants are wire errors, and which rescues this repository owns.
module KioskWireErrorScope
  def const_lookup(name)
    Object.const_get(name, false)
  rescue ::NameError, ::TypeError, ::LoadError
    nil
  end

  # Resolve an `Errors::X`, bare `X` or fully-qualified spelling the way the
  # `module Kiosk; module Server` nesting of a lib file resolves it.
  def resolve(path)
    joined = path.join('::')
    ["Kiosk::Server::Errors::#{joined}", "Kiosk::Server::#{joined}", joined].each do |candidate|
      found = const_lookup(candidate)
      return found if found
    end
    nil
  end

  # In scope: everything whose `message` can become a problem document's
  # `detail`, that is the error classes and the `Errors` module whose builders
  # return them.
  def in_scope?(const)
    return false if const.nil?
    return true if const.equal?(Kiosk::Server::Errors)

    # `<=` answers nil for two unrelated classes; this predicate answers false.
    const.is_a?(Class) && !(const <= Kiosk::Server::Errors::Base).nil? &&
      const <= Kiosk::Server::Errors::Base
  end

  # A rescue is owned when every class it names sits under `Kiosk::`.
  def owned_rescue?(exception_node)
    paths = maximal_const_paths(exception_node)
    !paths.empty? && paths.all? { |path| path.first == 'Kiosk' }
  end
end

# The rule: an exception message this repository does not own may not reach
# the constructor of a wire error.
#
# A wire error is a class that descends from `Kiosk::Server::Errors::Base`,
# because `Base#to_problem` copies its `message` into `detail`. So
# `Errors::ConfigurationError`, which has no `to_problem`, is out of scope.
#
# A message is owned when the variable it is read from was bound by a rescue
# whose every named class sits under `Kiosk::`. A bare `rescue => e` names
# nothing, so it is foreign.
#
# There are two constructions: an `Errors` constructor or raise, and `render`.
# A non-2xx render in a sub-dispatch becomes an `Errors::Base` whose `message`
# is the `detail`, so every `render` body is judged, with or without an `error`
# key.
#
# The sweep does not see:
#   * a message passed through a local first (`detail = e.message`, then
#     `Errors::BadRequest.new(detail)`);
#   * `#{e.class}`, a class name that cannot carry the caller's bytes.
module KioskWireErrorSweep
  extend KioskWireErrorNodes
  extend KioskWireErrorScope

  module_function

  Offence = Struct.new(:path, :line, :source, :variable)

  def scan(source, path: '(fixture)')
    tree = Ripper.sexp(source)
    raise ArgumentError, "#{path} does not parse" if tree.nil?

    result = { sites: 0, renders: 0, offences: [], owned: [] }
    walk(tree, {}, { result: result, lines: source.lines, path: path })
    result[:offences].uniq!
    result[:owned].uniq!
    result
  end

  def walk(node, env, ctx)
    return unless node.is_a?(Array)
    return walk_rescue(node, env, ctx) if node[0] == :rescue

    record(ctx, :sites, constructor_arguments(node), env)
    record(ctx, :renders, render_arguments(node), env)
    node.each { |child| walk(child, env, ctx) }
  end

  def walk_rescue(node, env, ctx)
    _, exception_node, var, body, following = node
    walk(exception_node, env, ctx)
    walk(body, rescue_env(env, exception_node, local_name(var, :var_field)), ctx)
    walk(following, env, ctx)
  end

  def rescue_env(env, exception_node, name)
    return env unless name

    env.merge(name => owned_rescue?(exception_node) ? :owned : :foreign)
  end

  def record(ctx, counter, args, env)
    return unless args

    ctx[:result][counter] += 1
    message_sends(args, env).each do |(line, name, ownership)|
      found = Offence.new(ctx[:path], line, ctx[:lines][line - 1].to_s.strip, name)
      ctx[:result][ownership == :owned ? :owned : :offences] << found
    end
  end

  # The spellings that build a wire error: `Errors::X.new(…)` and
  # `Errors.builder(…)`; `raise Errors::X, "…"`; and that raise with
  # parentheses.
  def constructor_arguments(node)
    case node[0]
    when :method_add_arg then paren_constructor_arguments(node)
    when :command, :command_call then command_raise_arguments(node)
    end
  end

  def paren_constructor_arguments(node)
    head = node[1]
    if type?(head, :call)
      node[2] if wire_error_call?(head)
    elsif type?(head, :fcall) && head[1].is_a?(Array) && head[1][1] == 'raise'
      node[2] if raised_wire_error?(node[2])
    end
  end

  def wire_error_call?(call)
    target = const_path(call[1])
    const  = target && resolve(target)
    ident?(call[3]) && in_scope?(const) && (call[3][1] == 'new' || const.equal?(Kiosk::Server::Errors))
  end

  def command_raise_arguments(node)
    ident = node[0] == :command ? node[1] : node[3]
    node.last if ident?(ident, 'raise') && raised_wire_error?(node.last)
  end

  # `render …`, with or without parentheses. The body is not inspected for an
  # `error` key: `render json: { message: e.message }` reaches a caller too.
  def render_arguments(node)
    case node[0]
    when :method_add_arg then node[2] if type?(node[1], :fcall) && ident?(node[1][1], 'render')
    when :command then node.last if ident?(node[1], 'render')
    end
  end

  def raised_wire_error?(args)
    return false unless args.is_a?(Array)

    path = const_path(first_argument(args))
    !path.nil? && in_scope?(resolve(path))
  end

  def first_argument(args)
    list = args[0] == :arg_paren ? args[1] : args
    list = list[1] if type?(list, :args_add_block)
    list[0] if list.is_a?(Array)
  end
end

module WireWordingSpec
  # Ruby-side leaks: `KeyError#message`, the json gem's parser wording, and an
  # object rendered by `to_s`. None of them may appear in a detail.
  RUBY_LEAKS = [/key not found/, /unexpected token/, /#</].freeze
  HOUSE_SENTENCES = ['missing field:', 'invalid JSON body'].freeze
  BUILDER_FILE    = 'lib/kiosk/server/errors.rb'
  # Floors well below the counts in app/ and lib/ and well above zero, so a sweep that
  # stops recognising sites cannot pass by judging nothing.
  MINIMUM_CONSTRUCTOR_SITES = 80
  MINIMUM_RENDER_SITES = 10

  def wire_user_idp(identity)
    idp = Class.new do
      def initialize(identity) = @identity = identity
      def verify(_request) = @identity
    end
    Kiosk.configure { |c| c.user_idp = idp.new(identity) }
  end

  def call_auth(action, raw_body)
    env = Rack::MockRequest.env_for(
      "https://provider.example/kiosk/auth/#{action}",
      method: 'POST', input: raw_body, 'CONTENT_TYPE' => 'application/json'
    )
    status, headers, body = Kiosk::Server::AuthController.action(action).call(env)
    raw = +''
    body.each { |chunk| raw << chunk }
    [status, headers, raw.empty? ? {} : JSON.parse(raw, symbolize_names: true)]
  end

  # The media type of a problem document, the flat `code` an assistant
  # branches on, and the exact `detail`.
  def expect_detail(status, headers, body, detail)
    expect(status).to eq(400)
    expect(headers['Content-Type']).to include('application/problem+json')
    expect(body[:code]).to eq('bad_request')
    expect(body[:detail]).to eq(detail)
  end

  def expect_no_ruby(body)
    RUBY_LEAKS.each { |leak| expect(body[:detail]).not_to match(leak) }
  end

  # The code of a file with comments removed. Ripper tells a comment from a
  # `#` inside a string.
  def code_without_comments(path)
    Ripper.lex(File.read(path))
          .reject { |(_, type, _)| %i[on_comment on_embdoc on_embdoc_beg].include?(type) }
          .map { |(_, _, tok)| tok }
          .join
  end

  # "rel:line: code" for every comment-free line of app/ and lib/ that holds a house
  # sentence and matches the block.
  def house_sentence_lines(&)
    sources.flat_map do |path|
      rel = path.delete_prefix("#{gem_root}/")
      code_without_comments(path).lines.each_with_index.filter_map do |line, idx|
        next unless WireWordingSpec::HOUSE_SENTENCES.any? { |s| line.include?(s) } && yield(rel, line)

        "#{rel}:#{idx + 1}: #{line.strip}"
      end
    end
  end

  def sweep(source) = KioskWireErrorSweep.scan(source, path: '(self-test)')
end

RSpec.shared_context 'wire wording spec: provider' do
  include WireWordingSpec

  let(:user_id) { '11111111-1111-1111-1111-111111111111' }

  before do
    Kiosk.configure do |c|
      c.issuer      = 'https://provider.example'
      c.signing_key = Kiosk::Server::SigningKey.generate
      c.roles       = %i[customer]
    end
  end
end

RSpec.shared_context 'wire wording spec: shipped sources' do
  include_context 'wire wording spec: provider'

  let(:gem_root) { File.expand_path('../../..', __dir__) }
  let(:sources)  { Dir.glob("#{gem_root}/{app,lib}/**/*.rb").sort }

  let(:census) do
    sources.each_with_object({ sites: 0, renders: 0, offences: [], owned: [] }) do |path, acc|
      found = KioskWireErrorSweep.scan(File.read(path), path: path.delete_prefix("#{gem_root}/"))
      acc[:sites]   += found[:sites]
      acc[:renders] += found[:renders]
      acc[:offences].concat(found[:offences])
      acc[:owned].concat(found[:owned])
    end
  end
end

RSpec.describe 'the malformed-request sentences on the wire' do
  include_context 'wire wording spec: provider'

  # The first call an assistant makes.
  describe 'POST /kiosk/auth/register' do
    it 'names the absent field and not the Ruby exception when public_key is omitted' do
      status, headers, body = call_auth(:register, JSON.generate(signed: 'x'))
      expect_detail(status, headers, body, 'missing field: public_key')
      expect_no_ruby(body)
    end

    it 'names the absent field when signed is omitted' do
      status, headers, body = call_auth(:register, JSON.generate(public_key: 'x'))
      expect_detail(status, headers, body, 'missing field: signed')
      expect_no_ruby(body)
    end

    it "answers a body that is not JSON with this protocol's own sentence" do
      status, headers, body = call_auth(:register, 'notjson')
      expect_detail(status, headers, body, 'invalid JSON body')
      expect_no_ruby(body)
      expect(body[:hint]).to eq(Kiosk::Server::Errors::MALFORMED_JSON_HINT)
    end
  end
end

RSpec.describe 'the malformed-request sentences on the wire' do
  include_context 'wire wording spec: provider'

  describe 'POST /kiosk/auth/login' do
    it 'names the absent field when signed is omitted' do
      status, headers, body = call_auth(:login, JSON.generate(public_key: 'x'))
      expect_detail(status, headers, body, 'missing field: signed')
      expect_no_ruby(body)
    end
  end

  # The register-shaped redeem.
  describe 'POST /kiosk/auth/claim' do
    it 'names the absent field when signed is omitted' do
      status, headers, body = call_auth(:claim, JSON.generate(code: 'c', public_key: 'PEM'))
      expect_detail(status, headers, body, 'missing field: signed')
      expect_no_ruby(body)
    end
  end

  # Behind the human's own session.
  describe 'POST /kiosk/auth/unlink' do
    it 'names the absent field when agent_id is omitted' do
      wire_user_idp(build_identity(actor: 'human', agent_id: nil, user_id: user_id))
      status, headers, body = call_auth(:unlink, JSON.generate({}))
      expect_detail(status, headers, body, 'missing field: agent_id')
      expect_no_ruby(body)
    end
  end
end

RSpec.describe 'the malformed-request sentences on the wire' do
  include_context 'wire wording spec: provider'

  describe 'Kiosk::Server::Errors.missing_field' do
    it 'names the KEY of a rescued KeyError, never its message' do
      err = begin
        {}.fetch(:public_key)
      rescue KeyError => e
        e
      end
      expect(err.message).to include('key not found')
      expect(Kiosk::Server::Errors.missing_field(err).message).to eq('missing field: public_key')
    end

    it 'accepts a bare field name too, so a site with no exception can use it' do
      expect(Kiosk::Server::Errors.missing_field('agent_id').message).to eq('missing field: agent_id')
    end

    it 'falls back to plain words — never to `message` — for a KeyError carrying no key' do
      built = Kiosk::Server::Errors.missing_field(KeyError.new('key not found: :smuggled'))
      expect(built.message).to eq('request is missing a required field')
      expect(built.message).not_to include('smuggled')
    end
  end
end

RSpec.describe 'the malformed-request sentences on the wire' do
  include_context 'wire wording spec: provider'

  describe 'Kiosk::Server::Errors.malformed_json' do
    it 'is the whole detail, with the recovery sentence in the hint' do
      built = Kiosk::Server::Errors.malformed_json
      expect(built.message).to eq('invalid JSON body')
      expect(built.hint).to eq(Kiosk::Server::Errors::MALFORMED_JSON_HINT)
    end

    it 'lets a site narrow the hint without touching the detail' do
      built = Kiosk::Server::Errors.malformed_json(hint: "a query's arguments are in the query string.")
      expect(built.message).to eq('invalid JSON body')
      expect(built.hint).to eq("a query's arguments are in the query string.")
    end
  end
end

# The sentence for a Rails-native raise.
RSpec.describe 'the malformed-request sentences on the wire' do
  include_context 'wire wording spec: provider'

  describe 'Kiosk::Server::Errors.rescued_wire' do
    it 'words the refusal itself and names the verb, so nothing of the exception travels' do
      built = Kiosk::Server::Errors.rescued_wire('bad_request', verb: 'strict')
      expect(built[:code]).to eq('bad_request')
      expect(built[:message]).to eq('verb "strict" rejected the request as malformed')
      expect(built[:hint]).to eq(Kiosk::Server::Errors::RESCUED_HINTS.fetch('bad_request'))
    end

    it 'says `this verb` when the dispatch name is unknown, rather than rendering nil' do
      expect(Kiosk::Server::Errors.rescued_wire('not_found')[:message])
        .to eq('this verb found no such record')
      expect(Kiosk::Server::Errors.rescued_wire('not_found', verb: '')[:message])
        .to eq('this verb found no such record')
    end
  end
end

RSpec.describe 'the malformed-request sentences on the wire' do
  include_context 'wire wording spec: provider'

  describe 'Kiosk::Server::Errors.rescued_wire' do
    # The rescue seam reaches this builder for every code STATUS_CODES can
    # decide. A code it cannot word would be a KeyError, so a 500, at request time.
    it 'words every code the rescue seam can decide, and invents none' do
      reachable = Kiosk::Server::Errors::STATUS_CODES.values.uniq.sort
      expect(Kiosk::Server::Errors::RESCUED_DETAILS.keys.sort).to eq(reachable)
      expect(Kiosk::Server::Errors::RESCUED_HINTS.keys.sort).to eq(reachable)
    end

    it 'carries no Ruby, no library and no exception wording in any entry' do
      Kiosk::Server::Errors::STATUS_CODES.values.uniq.each do |code|
        built = Kiosk::Server::Errors.rescued_wire(code, verb: 'v')
        expect(built[:message]).not_to be_empty
        expect(built[:hint]).not_to be_empty
        WireWordingSpec::RUBY_LEAKS.each do |leak|
          expect(built[:message]).not_to match(leak)
          expect(built[:hint]).not_to match(leak)
        end
      end
    end
  end
end

# No site builds a house sentence for itself. Outside errors.rb, where the
# builders live, neither sentence appears at all, literal or interpolated.
# Comments are stripped first, so quotations of the bad strings do not count.
RSpec.describe 'the malformed-request sentences on the wire' do
  include_context 'wire wording spec: shipped sources'

  describe "kiosk-server's source" do
    it 'has sources to sweep and a builder file among them (vacuity)' do
      expect(sources).not_to be_empty
      expect(sources.map { |p| p.delete_prefix("#{gem_root}/") }).to include(WireWordingSpec::BUILDER_FILE)
    end

    it 'still contains both house sentences somewhere, or this sweep guards nothing (vacuity)' do
      WireWordingSpec::HOUSE_SENTENCES.each do |sentence|
        expect(sources.any? { |p| code_without_comments(p).include?(sentence) })
          .to be(true), "no shipped line says #{sentence.inspect} any more — re-aim this sweep"
      end
    end
  end
end

RSpec.describe 'the malformed-request sentences on the wire' do
  include_context 'wire wording spec: shipped sources'

  describe "kiosk-server's source" do
    it 'builds `missing field:` and `invalid JSON body` nowhere but errors.rb, literal or interpolated' do
      expect(house_sentence_lines { |rel, _| rel != WireWordingSpec::BUILDER_FILE }).to be_empty
    end

    # errors.rb may interpolate, since it holds the builders, but not an
    # exception's message.
    it "never splices an exception's message into either sentence, errors.rb included" do
      expect(house_sentence_lines { |_, line| line.match?(/\#\{[^}]*\bmessage\b/) }).to be_empty
    end
  end
end

# No foreign message reaches a wire error. The rule and its blind spots are on
# KioskWireErrorSweep at the top of this file.
RSpec.describe 'the malformed-request sentences on the wire' do
  include_context 'wire wording spec: shipped sources'

  describe "kiosk-server's wire errors" do
    it 'never lets an exception message this repository does not own reach a wire error' do
      expect(census[:offences].map { |o| "#{o.path}:#{o.line}: #{o.source}" }).to be_empty
    end

    it 'resolves the constants it keys on, and draws its scope line where it says it does (vacuity)' do
      expect(KioskWireErrorSweep.resolve(%w[Errors BadRequest]))
        .to be(Kiosk::Server::Errors::BadRequest)
      expect(KioskWireErrorSweep.resolve(%w[Errors])).to be(Kiosk::Server::Errors)
      expect(KioskWireErrorSweep.in_scope?(Kiosk::Server::Errors::BadRequest)).to be(true)
      expect(KioskWireErrorSweep.in_scope?(Kiosk::Server::Errors)).to be(true)
      # ConfigurationError never becomes a problem document.
      expect(KioskWireErrorSweep.in_scope?(Kiosk::Server::Errors::ConfigurationError)).to be(false)
    end
  end
end

# Vacuity: each way the sweep could stop seeing sites fails here.
RSpec.describe 'the malformed-request sentences on the wire' do
  include_context 'wire wording spec: shipped sources'

  describe "kiosk-server's wire errors" do
    it 'still recognises wire-error constructors in the shipped source (vacuity)' do
      expect(census[:sites]).to be >= WireWordingSpec::MINIMUM_CONSTRUCTOR_SITES,
                                "the sweep found #{census[:sites]} constructor sites in app/ and lib/ — it has stopped " \
                                'recognising them, and an empty offence list means nothing until it does'
    end

    it 'still recognises `render` sites in the shipped source (vacuity)' do
      expect(census[:renders]).to be >= WireWordingSpec::MINIMUM_RENDER_SITES,
                                  "the sweep found #{census[:renders]} render sites in app/ and lib/ — the render " \
                                  'arm has stopped recognising them, and it covers the sub-dispatch envelope'
    end

    it 'still finds one of OUR OWN messages reaching a wire error, or the carve-out guards nothing (vacuity)' do
      expect(census[:owned]).not_to be_empty,
                                    "no shipped site re-raises a Kiosk-owned exception's message any more — the " \
                                    'ownership carve-out now excuses nothing that exists, so re-aim it or delete it'
    end
  end
end

RSpec.describe 'the malformed-request sentences on the wire' do
  include_context 'wire wording spec: provider'

  describe "kiosk-server's wire errors" do
    it 'reports a foreign message spliced into a wire error (self-test)' do
      found = sweep(<<~'RUBY')
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
      expect(found[:offences].size).to eq(1)
      expect(found[:offences].first.line).to eq(7)
      expect(found[:owned]).to be_empty
    end
  end
end

RSpec.describe 'the malformed-request sentences on the wire' do
  include_context 'wire wording spec: provider'

  describe "kiosk-server's wire errors" do
    it 'reports one spliced into a HINT, which reaches the wire too (self-test)' do
      source = <<~'RUBY'
        rescue Rack::BadRequest => e
          raise Errors::BadRequest.new("undecodable", hint: "rack said #{e.message}")
        end
      RUBY
      expect(sweep("begin\n#{source}")[:offences].size).to eq(1)
    end

    it 'reports the comma form, which carries no `.new` to key on (self-test)' do
      source = <<~'RUBY'
        begin
          nil
        rescue StandardError => e
          raise Errors::Unauthenticated, "proof rejected: #{e.message}"
        end
      RUBY
      expect(sweep(source)[:offences].size).to eq(1)
    end
  end
end

RSpec.describe 'the malformed-request sentences on the wire' do
  include_context 'wire wording spec: provider'

  describe "kiosk-server's wire errors" do
    it 'excuses a Kiosk-owned message, and ONLY a Kiosk-owned one (self-test)' do
      ours = <<~RUBY
        begin
          nil
        rescue Kiosk::PaymentProviders::PaymentFailed => e
          raise Errors::PaymentFailed.new(e.message, hint: "retry")
        end
      RUBY
      theirs = ours.sub('Kiosk::PaymentProviders::PaymentFailed', 'StandardError')

      expect(sweep(ours)[:offences]).to be_empty
      expect(sweep(ours)[:owned].size).to eq(1)
      expect(sweep(theirs)[:offences].size).to eq(1)
    end
  end
end

RSpec.describe 'the malformed-request sentences on the wire' do
  include_context 'wire wording spec: provider'

  describe "kiosk-server's wire errors" do
    it 'treats a bare `rescue => e`, which names nothing, as foreign (self-test)' do
      source = <<~'RUBY'
        begin
          nil
        rescue => e
          raise Errors::BadRequest.new("no: #{e.message}")
        end
      RUBY
      expect(sweep(source)[:offences].size).to eq(1)
    end
  end
end

# The sub-dispatch envelope is a wire error too.
RSpec.describe 'the malformed-request sentences on the wire' do
  include_context 'wire wording spec: provider'

  describe "kiosk-server's wire errors" do
    # No `Errors` constructor on the line: only the render arm sees it.
    it 'reports a foreign message rendered into the sub-dispatch envelope (self-test)' do
      found = sweep(<<~RUBY)
        begin
          nil
        rescue StandardError => exception
          render json: {
            ok:    false,
            error: { code: code, message: exception.message },
          }, status: 400
        end
      RUBY
      expect(found[:offences].size).to eq(1)
      expect(found[:renders]).to eq(1)
    end
  end
end

RSpec.describe 'the malformed-request sentences on the wire' do
  include_context 'wire wording spec: provider'

  describe "kiosk-server's wire errors" do
    # `rescue_from(StandardError, with: :kiosk_rescue_to_wire)` passes the
    # exception as an argument, so no rescue owns it and it is foreign.
    it 'reports one rendered by a method PARAMETER, which no rescue owns (self-test)' do
      source = <<~RUBY
        def kiosk_rescue_to_wire(exception)
          render(json: { error: { message: exception.message } }, status: 400)
        end
      RUBY
      expect(sweep(source)[:offences].size).to eq(1)
    end

    it 'excuses a Kiosk-owned message in a render, on the same terms (self-test)' do
      found = sweep(<<~RUBY)
        begin
          nil
        rescue Kiosk::PaymentProviders::PaymentFailed => e
          render json: { error: { message: e.message } }, status: 402
        end
      RUBY
      expect(found[:offences]).to be_empty
      expect(found[:owned].size).to eq(1)
    end
  end
end

RSpec.describe 'the malformed-request sentences on the wire' do
  include_context 'wire wording spec: provider'

  describe "kiosk-server's wire errors" do
    it 'leaves a render that carries no exception message alone (self-test)' do
      found = sweep(<<~RUBY)
        render json: { ok: false, error: Errors.rescued_wire(code, verb: name) }, status: 400
      RUBY
      expect(found[:offences]).to be_empty
      expect(found[:renders]).to eq(1)
    end

    it 'leaves a non-wire error alone, which is where its scope line falls (self-test)' do
      found = sweep(<<~'RUBY')
        begin
          nil
        rescue NameError => e
          raise Errors::ConfigurationError, "does not resolve (#{e.class}: #{e.message})"
        end
      RUBY
      expect(found[:offences]).to be_empty
      expect(found[:sites]).to eq(0)
    end
  end
end
