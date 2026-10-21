# frozen_string_literal: true

require 'action_dispatch/routing'

module Kiosk
  module Server
    # `kiosk do … end` in config/routes.rb. Mounts the engine at the configured
    # mount_path first, so the protocol plane wins by first match, then draws
    # GET <mount_path>/<name> for each query and POST for each action, each to
    # the controller action that declares the verb.
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

        def queries(*names) = draw(:get, :query, names)
        def actions(*names) = draw(:post, :action, names)

        private

        def draw(method, kind, names)
          names.each do |name|
            @mapper.public_send(method, "#{Kiosk.configuration.mount_path}/#{name}", to: VerbRoute.new(kind, name.to_s))
          end
        end
      end

      # The endpoint of one verb route. The controller action that declares the
      # verb answers the protocol request; the name is looked up per request, so a
      # development reload is served. A name that no action answers goes to
      # {VerbController}, which refuses it.
      class VerbRoute
        attr_reader :kind, :name

        def initialize(kind, name)
          @kind = kind
          @name = name
        end

        def call(env)
          controller, action, extra = target
          env[HandlerServing::VERB_KEY] = @name
          env['action_dispatch.request.path_parameters'] = { controller: controller.controller_path, action: action, **extra }
          controller.action(action).call(env)
        end

        # The action this route reaches now, as `controller#action`; `bin/rails routes` prints it.
        def endpoint = target.then { |controller, action| "#{controller.controller_path}##{action}" }
        alias inspect endpoint

        private

        def target
          registry = HandlerMixin.registry_for(@kind)
          handler  = registry.fetch(@name) if registry.known.include?(@name)
          controller = handler.controller if handler.is_a?(ControllerVerb)
          return [controller, handler.method_name, {}] if controller

          [VerbController, @kind == :query ? 'show' : 'create', { kiosk_verb: @name }]
        end
      end
    end
  end
end
