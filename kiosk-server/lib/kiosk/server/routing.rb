# frozen_string_literal: true

require 'action_dispatch/routing'

module Kiosk
  module Server
    # `kiosk do … end` in config/routes.rb. Mounts the engine at the configured
    # mount_path first, so the protocol plane wins by first match, then draws
    # GET <mount_path>/<name> for each query and POST for each action.
    #
    #   kiosk do
    #     queries :catalog
    #     actions :place_order
    #   end
    module Routing
      def kiosk(&block)
        mount Kiosk::Server::Engine => Kiosk.configuration.mount_path
        Verbs.new(self).instance_exec(&block) if block
      end

      # The block's receiver: a query or an action are the only verbs there are.
      class Verbs
        def initialize(mapper)
          @mapper = mapper
        end

        def queries(*names) = draw(:get, 'show', names)
        def actions(*names) = draw(:post, 'create', names)

        private

        def draw(method, action, names)
          names.each do |name|
            @mapper.public_send(method, "#{Kiosk.configuration.mount_path}/#{name}",
                                to: "kiosk/server/verb##{action}", defaults: { kiosk_verb: name.to_s })
          end
        end
      end
    end
  end
end

ActionDispatch::Routing::Mapper.include(Kiosk::Server::Routing)
