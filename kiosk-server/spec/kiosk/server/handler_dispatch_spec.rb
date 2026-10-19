# frozen_string_literal: true

# The callable the mixin puts in the registry (T-053). The operator-facing
# behaviour lives in handler_mixin_spec.rb; this covers what the seam does when
# the handler misbehaves, plus the reload property the whole design rests on.
#
# `ApplicationController` (the fake host base class) is defined in spec_helper.rb.

require 'rack/mock'
require 'json'
require_relative '../../support/b1_handler_classes'

# A NAMED handler class — the reload test needs one, because a named class is
# held in the registry by name and re-resolved on every call, while an anonymous
# one can only be held directly.
class SpecReloadableController < ApplicationController
  include Kiosk::Handler

  kind :query
  description "Lists the shop's stock."
  input_schema type: 'object', additionalProperties: false, properties: {}, required: []
  output_schema true
  def reloadable = render(json: [{ 'sku' => 'ORIGINAL' }])
end

module HandlerDispatchSpec
  # The wire NAME is its own argument — a path segment on the wire, never
  # a body field — so it is lifted out of `args` here exactly as
  # {Kiosk::Server::VerbController} lifts it out of `params[:kiosk_verb]`.
  def execute(kind, args)
    args = args.dup
    name = (args.delete(:name) || args.delete('name')).to_s
    Kiosk::Server::CurrentRequest.with(identity: identity) do
      Kiosk::Server::Executor.call(kind: kind, args: args, identity: identity,
                                   connection: connection, name: name.empty? ? nil : name)
    end
  end

  def write_shelf_views(views)
    FileUtils.mkdir_p(File.join(views, 'spec_templated'))
    File.write(File.join(views, 'spec_templated', 'shelf.json.erb'),
               '[{"sku": "<%= @sku %>"}]')
    File.write(File.join(views, 'spec_templated', 'shelf.html.erb'), '<p>not the wire</p>')
    File.write(File.join(views, 'spec_templated', 'shelf_page.json.erb'),
               '[{"sku": "<%= @sku %>"}]')
  end
end

RSpec.shared_context 'handler dispatch spec: executor' do
  include B1HandlerClasses
  include HandlerDispatchSpec

  let(:identity)   { build_identity(user_id: 'u-1', agent_id: 'a-1') }
  let(:connection) { FakeConnection.new }
end

RSpec.shared_context 'handler dispatch spec: templated handler' do
  around do |example|
    Dir.mktmpdir do |views|
      write_shelf_views(views)
      @views = views
      example.run
    end
  end

  before do
    views = @views
    klass = stub_handler('SpecTemplatedController', :query, "Lists the shop's stock.") do
      prepend_view_path views
      def shelf = @sku = 'MILK-1L'
    end
    declare_verb(klass, :query, "Lists the shop's stock one page at a time.")
    klass.define_method(:shelf_page) do
      @sku = 'OATS-500G'
      render_kiosk_page(next_cursor: '1', total: 2)
    end
    klass.kiosk_register!
  end
end

RSpec.describe Kiosk::Server::HandlerDispatch do
  include_context 'handler dispatch spec: executor'

  describe 'reload safety' do
    before { SpecReloadableController.kiosk_register! }

    it 'holds a named controller by NAME, so a reloaded class is picked up' do
      handler = Kiosk::Server::Queries.fetch('reloadable')
      expect(handler.controller_name).to eq('SpecReloadableController')
      expect(execute(:query, { name: 'reloadable' }).payload).to eq([{ 'sku' => 'ORIGINAL' }])

      # What Zeitwerk does on a code reload: same constant, new class object.
      stub_handler('SpecReloadableController', :query, 'The edited handler.') do
        def reloadable = render(json: [{ 'sku' => 'EDITED' }])
      end

      expect(execute(:query, { name: 'reloadable' }).payload).to eq([{ 'sku' => 'EDITED' }])
    end

    it 'answers not_found when the controller constant is gone' do
      hide_const('SpecReloadableController')

      expect { execute(:query, { name: 'reloadable' }) }
        .to raise_error(Kiosk::Server::Errors::VerbNotFound, /is not loaded/)
    end
  end
end

RSpec.describe Kiosk::Server::HandlerDispatch do
  include_context 'handler dispatch spec: executor'

  describe 'a handler that does not answer with JSON' do
    it 'fails loudly rather than putting HTML on the wire' do
      stub_handler('SpecHtmlController', :query, 'Renders HTML, which the wire cannot carry.') do
        def html_query = render(html: '<p>nope</p>'.html_safe)
      end

      expect { execute(:query, { name: 'html_query' }) }
        .to raise_error(Kiosk::Server::Errors::ActionFailed, /non-JSON body/)
    end

    it 'reports an unmapped status rather than guessing a wire code' do
      # 402 is three different wire codes (pow_required, payment_setup_required,
      # payment_failed); the seam refuses to pick one. A handler that means a
      # specific 402 raises the Errors class.
      stub_handler('SpecBare402Controller', :action, 'Renders a bare 402.') do
        def bare_payment_required = render(json: { error: 'pay up' }, status: :payment_required)
      end

      expect { execute(:run, { name: 'bare_payment_required' }) }
        .to raise_error(Kiosk::Server::Errors::ActionFailed, /pay up/)
    end
  end
end

RSpec.describe Kiosk::Server::HandlerDispatch do
  include_context 'handler dispatch spec: executor'

  describe 'a handler that does not answer with JSON' do
    it "never mistakes an operator's own code field for the wire vocabulary" do
      stub_handler('SpecSoldOutController', :action, "Answers a domain refusal with the app's own error code.") do
        def sold_out
          render json: { error: { code: 'out_of_stock', message: 'sold out' } }, status: :conflict
        end
      end

      expect { execute(:run, { name: 'sold_out' }) }
        .to raise_error(Kiosk::Server::Errors::Base) { |e|
          expect(e.code).to eq('conflict')
          expect(e.message).to eq('sold out')
        }
    end
  end
end

RSpec.describe Kiosk::Server::HandlerDispatch do
  include_context 'handler dispatch spec: executor'

  describe 'a handler that renders its own problem members' do
    it 'keeps type, title and status those of the code, and drops instance and challenges' do
      stub_handler('SpecSelfTitledController', :action, 'Renders RFC members of its own on a 409.') do
        def self_titled
          render json: { error: { code: 'conflict', message: 'taken', status: 200, type: 'urn:mine',
                                  title: 'Mine', detail: 'mine', instance: '/i/1', challenges: [1],
                                  slot: 'S-1' } },
                 status: :conflict
        end
      end

      expect { execute(:run, { name: 'self_titled' }) }
        .to raise_error(Kiosk::Server::Errors::Base) { |e|
          expect(e.to_problem).to eq(type: 'https://kiosk.tech/problems/conflict', title: 'State conflict',
                                     status: 409, detail: 'taken', code: 'conflict', slot: 'S-1')
        }
    end

    it 'carries the challenges a handler renders on pow_required' do
      stub_handler('SpecSelfTolledController', :action, 'Renders its own proof-of-work refusal.') do
        def self_tolled
          render json: { error: { code: 'pow_required', message: 'solve', challenges: [1] } },
                 status: :payment_required
        end
      end

      expect { execute(:run, { name: 'self_tolled' }) }
        .to raise_error(Kiosk::Server::Errors::Base) { |e| expect(e.to_problem[:challenges]).to eq([1]) }
    end
  end
end

RSpec.describe Kiosk::Server::HandlerDispatch do
  include_context 'handler dispatch spec: executor'

  describe 'a handler that does not answer with JSON' do
    it 'falls back to the status when a rendered code does not belong to it' do
      # pow_required is a 402 code; rendered on a 403 it is a handler bug, and
      # the seam answers with what the status alone says rather than putting a
      # mislabelled code on the wire.
      stub_handler('SpecMislabelledController', :query, 'Renders a 402 code on a 403 status.') do
        def mislabelled
          render json: { ok: false, error: { code: 'pow_required', message: 'nope' } },
                 status: :forbidden
        end
      end

      expect { execute(:query, { name: 'mislabelled' }) }
        .to raise_error(Kiosk::Server::Errors::Base) { |e| expect(e.code).to eq('forbidden') }
    end

    it 'rejects a page whose rows are not an array' do
      stub_handler('SpecBadPageController', :query, 'Pages an object instead of rows.') do
        def bad_page = render_kiosk_page({ items: [] })
      end

      expect { execute(:query, { name: 'bad_page' }) }
        .to raise_error(Kiosk::Server::Errors::ActionFailed, /not an array of rows/)
    end

    it 'rejects a query that answers an object, paginating or not' do
      stub_handler('SpecObjectQueryController', :query, 'Answers one object.') do
        def one_object = render(json: { id: 1 })
      end

      expect { execute(:query, { name: 'one_object' }) }
        .to raise_error(Kiosk::Server::Errors::ActionFailed, /not an array of rows/)
    end

    it 'refuses an empty next_cursor, whose next link would lead back to page one' do
      stub_handler('SpecEmptyCursorController', :query, 'Pages with an empty cursor.') do
        def empty_cursor = render_kiosk_page([{ id: 1 }], next_cursor: '')
      end

      expect(Kiosk::Server::FailureLog)
        .to receive(:report).with(/raised ArgumentError/, having_attributes(message: /next_cursor is empty/))
      expect { execute(:query, { name: 'empty_cursor' }) }
        .to raise_error(Kiosk::Server::Errors::ActionFailed)
    end
  end
end

RSpec.describe Kiosk::Server::HandlerDispatch do
  include_context 'handler dispatch spec: executor'

  describe 'a handler answering through its template' do
    include_context 'handler dispatch spec: templated handler'

    it 'leaves ActionController loading to the host, so a view library can set it up first' do
      script = 'require "kiosk/server"; ' \
               'exit($LOADED_FEATURES.grep(%r{/action_controller/(api|base)[.]rb\z}).empty? ? 0 : 1)'
      expect(system(RbConfig.ruby, '-e', script, chdir: File.expand_path('../../..', __dir__))).to be(true)
    end

    it "renders the JSON template whatever the caller's Accept header asks for" do
      result = Kiosk::Server::CurrentRequest.with(identity: identity,
                                                  env: { 'HTTP_ACCEPT' => 'text/html' }) do
        Kiosk::Server::Executor.call(kind: :query, args: {}, identity: identity,
                                     connection: connection, name: 'shelf')
      end
      expect(result.payload).to eq([{ 'sku' => 'MILK-1L' }])
    end

    it 'pages the rows the template renders' do
      result = execute(:query, { name: 'shelf_page' })
      expect([result.payload, result.next_cursor, result.total])
        .to eq([[{ 'sku' => 'OATS-500G' }], '1', 2])
    end
  end
end

RSpec.describe Kiosk::Server::HandlerDispatch do
  include_context 'handler dispatch spec: executor'

  describe 'outside a wire request' do
    it 'runs with no identity and no caller headers (the RLS journey case)' do
      stub_handler('SpecBareController', :query, 'Reports what it can see.') do
        def bare = render(json: [{ identity: kiosk_identity, ua: request.headers['User-Agent'] }])
      end

      result = Kiosk::Server::Queries.fetch('bare').call({})

      expect(result).to eq([{ 'identity' => nil, 'ua' => nil }])
    end
  end

  describe 'an empty answer' do
    it 'carries a bodiless 200 through as a nil value' do
      stub_handler('SpecAckController', :action, 'Acknowledges and returns nothing.') do
        def ack = head(:ok)
      end

      expect(execute(:run, { name: 'ack' }).payload).to be_nil
    end
  end
end
