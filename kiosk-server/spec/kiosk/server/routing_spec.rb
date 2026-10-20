# frozen_string_literal: true

module RoutingSpecHelpers
  def draw(&)
    ActionDispatch::Routing::RouteSet.new.tap { |set| set.draw(&) }
  end

  # The verb the route at `method path` is drawn to, or nil when no verb route matches.
  def recognize(set, method, path)
    route = set.routes.find do |r|
      r.app.app.is_a?(Kiosk::Server::Routing::VerbRoute) && r.verb == method.to_s.upcase && r.path.match(path)
    end
    { kind: route.app.app.kind, name: route.app.app.name } if route
  end

  def routes
    @routes ||= draw do
      kiosk do
        queries :catalog, :my_orders
        actions :place_order
      end
    end
  end
end

RSpec.describe Kiosk::Server::Routing do
  include RoutingSpecHelpers

  it 'mounts the engine FIRST, so the protocol plane wins by first match' do
    first = routes.routes.first
    expect(first.app.app).to eq(Kiosk::Server::Engine)
    expect(first.path.spec.to_s).to eq('/kiosk')
  end

  it 'draws GET <mount_path>/<name> for each query' do
    %w[catalog my_orders].each do |name|
      expect(recognize(routes, :get, "/kiosk/#{name}")).to eq(kind: :query, name: name)
    end
  end

  it 'draws POST <mount_path>/<name> for each action' do
    expect(recognize(routes, :post, '/kiosk/place_order')).to eq(kind: :action, name: 'place_order')
  end

  it "draws no other method on a verb's path" do
    expect(recognize(routes, :post, '/kiosk/catalog')).to be_nil
    expect(recognize(routes, :get, '/kiosk/place_order')).to be_nil
  end
end

RSpec.describe Kiosk::Server::Routing, 'the kiosk block' do
  include RoutingSpecHelpers

  it 'honours the configured mount_path' do
    previous = Kiosk.configuration.mount_path
    Kiosk.configuration.mount_path = '/api'
    set = draw { kiosk { queries :catalog } }

    expect(set.routes.first.path.spec.to_s).to eq('/api')
    expect(recognize(set, :get, '/api/catalog')).to eq(kind: :query, name: 'catalog')
  ensure
    Kiosk.configuration.mount_path = previous
  end

  it 'only mounts when given no block' do
    set = draw { kiosk }
    expect(set.routes.map { |route| route.app.app }).to eq([Kiosk::Server::Engine])
  end

  it 'knows no kind besides queries and actions' do
    expect { draw { kiosk { verbs :catalog } } }.to raise_error(NoMethodError, /verbs/)
  end
end
