# frozen_string_literal: true

# The controller lists in `kiosk/server.rb` (the require block and the
# «Pieces shipped in this gem» manifest) name exactly the controllers on disk.
RSpec.describe "kiosk/server.rb's controller manifest" do
  SERVER_ENTRY_PATH   = File.expand_path("../../../lib/kiosk/server.rb", __dir__)
  CONTROLLER_LIB_GLOB = File.expand_path("../../../lib/kiosk/server/*_controller.rb", __dir__)

  # `open_api_controller.rb` → `OpenApiController`. Plain segment capitalisation
  # rather than an inflector: the inflector has acronym rules an operator can
  # configure, and this derivation must answer the same in every host.
  def self.controller_class_names
    Dir.glob(CONTROLLER_LIB_GLOB).sort.map do |path|
      File.basename(path, ".rb").split("_").map(&:capitalize).join
    end
  end

  let(:entry)   { File.read(SERVER_ENTRY_PATH) }
  let(:names)   { self.class.controller_class_names }

  it "finds the controllers on disk at all" do
    # A vacuity arm: an empty derivation would make every example below pass by
    # comparing nothing, which is the shape this file exists to prevent.
    expect(names).not_to be_empty,
                         "no `*_controller.rb` was found beside kiosk/server/. The oracle is the " \
                         "directory; if the layout moved, move this example with it rather than " \
                         "letting an empty set agree with every list."
  end

  it "defines each of them as a constant under Kiosk::Server" do
    missing = names.reject { |n| Kiosk::Server.const_defined?(n, false) }
    expect(missing).to be_empty,
                       "#{missing.join(", ")} — a `*_controller.rb` file whose class is named " \
                       "something else. The two lists in server.rb are written in class names, " \
                       "so a file that does not define its own name makes them uncheckable."
  end

  it "requires every one of them" do
    missing = names.reject do |name|
      require_path = name.gsub(/([a-z])([A-Z])/, '\1_\2').downcase
      entry.include?(%(require "kiosk/server/#{require_path}"))
    end
    expect(missing).to be_empty,
                       "server.rb does not require #{missing.join(", ")}. This file is what " \
                       "`require \"kiosk/server\"` loads; a controller it does not require is " \
                       "loaded only by autoload luck."
  end

  it "names every one of them in the «Pieces shipped in this gem» manifest" do
    manifest = entry[/#\s+Pieces shipped in this gem:.*/m]
    expect(manifest).not_to be_nil,
                            "server.rb has no «Pieces shipped in this gem» block. That manifest is " \
                            "the inventory a reader of the gem meets first; if it moved, move this " \
                            "example with it."

    missing = names.reject { |name| manifest.include?("{Kiosk::Server::#{name}}") }
    expect(missing).to be_empty,
                       "the manifest never names #{missing.join(", ")}. A controller the gem ships, " \
                       "requires and routes to, missing from the list of what it ships, is the " \
                       "K-1651 defect exactly."
  end
end
