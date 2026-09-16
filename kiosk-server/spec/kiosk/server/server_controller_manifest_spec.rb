# frozen_string_literal: true

# `server.rb` IS THE GEM'S FRONT DOOR, AND BOTH OF ITS CONTROLLER LISTS WERE
# HAND-KEPT (K-1651).
#
# The file `require "kiosk/server"` loads opens by saying what the gem is and
# closes with a «Pieces shipped in this gem» manifest. Between them sits the
# require block that actually loads the controllers. All three are prose, and
# two of them had fallen behind the directory: the opening sentence counted
# «the nine wire/auth/discovery controllers» against eleven tracked files, and
# neither the require-block comment nor the manifest named `OpenApiController`
# at all — although the same file requires it, the engine draws `openapi.json`
# to it, and it serves one of the two public documents under the mount.
#
# Nothing could have caught that. `bin/check-prose-counts` gates Markdown,
# environment templates, rake descriptions and gemspec strings and REPORTS Ruby
# comments without reddening, so a cardinal in a `.rb` comment is outside it by
# design. This example is the join that was missing, and it is deliberately
# narrow: it says nothing about WHAT a controller is for — that sentence is the
# human's — only that the SET the two lists carry is the set on disk.
#
# The opening sentence now carries no cardinal at all, which is why no example
# here counts one: a sentence with no number in it cannot go stale, and that is
# a better repair than a guarded number.
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
