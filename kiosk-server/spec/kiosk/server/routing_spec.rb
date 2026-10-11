# frozen_string_literal: true

RSpec.describe Kiosk::Server::Routing do
  def draw(&block)
    ActionDispatch::Routing::RouteSet.new.tap { |set| set.draw(&block) }
  end

  def recognize(set, method, path)
    set.recognize_path(path, method: method)
  end

  let(:routes) do
    draw do
      kiosk do
        queries :catalog, :my_orders
        actions :place_order
      end
    end
  end

  it "mounts the engine FIRST, so the protocol plane wins by first match" do
    first = routes.routes.first
    expect(first.app.app).to eq(Kiosk::Server::Engine)
    expect(first.path.spec.to_s).to eq("/kiosk")
  end

  it "draws GET <mount_path>/<name> for each query" do
    %w[catalog my_orders].each do |name|
      expect(recognize(routes, :get, "/kiosk/#{name}"))
        .to eq(controller: "kiosk/server/verb", action: "show", kiosk_verb: name)
    end
  end

  it "draws POST <mount_path>/<name> for each action" do
    expect(recognize(routes, :post, "/kiosk/place_order"))
      .to eq(controller: "kiosk/server/verb", action: "create", kiosk_verb: "place_order")
  end

  it "draws no other method on a verb's path" do
    expect { recognize(routes, :post, "/kiosk/catalog") }.to raise_error(ActionController::RoutingError)
    expect { recognize(routes, :get, "/kiosk/place_order") }.to raise_error(ActionController::RoutingError)
  end

  it "honours the configured mount_path" do
    previous = Kiosk.configuration.mount_path
    Kiosk.configuration.mount_path = "/api"
    set = draw { kiosk { queries :catalog } }

    expect(set.routes.first.path.spec.to_s).to eq("/api")
    expect(recognize(set, :get, "/api/catalog")).to include(kiosk_verb: "catalog")
  ensure
    Kiosk.configuration.mount_path = previous
  end

  it "only mounts when given no block" do
    set = draw { kiosk }
    expect(set.routes.map { |route| route.app.app }).to eq([Kiosk::Server::Engine])
  end

  it "knows no kind besides queries and actions" do
    expect { draw { kiosk { verbs :catalog } } }.to raise_error(NoMethodError, /verbs/)
  end
end
