# frozen_string_literal: true

module Kiosk
  module Server
    # The registry entry of a verb that a controller action answers. A named
    # controller is held by name and resolved per request, so a development
    # reload serves the edited class.
    class ControllerVerb
      attr_reader :method_name, :wire_name, :kind

      def initialize(controller:, method_name:, wire_name:, kind:)
        @controller  = controller.is_a?(Class) && controller.name ? controller.name : controller
        @method_name = method_name.to_s
        @wire_name   = wire_name.to_s
        @kind        = kind
      end

      # nil for an anonymous controller class.
      def controller_name = @controller.is_a?(String) ? @controller : @controller.name

      # The controller class whose action answers the verb, or nil when none can.
      def controller
        resolve!
      rescue Errors::VerbNotFound
        nil
      end

      # {VerbController} reaches this only when {#controller} is nil; it raises why no action answers.
      def call(_args)
        controller = resolve!
        raise ArgumentError, "#{controller}##{@method_name} answers #{@wire_name.inspect} through its own route"
      end

      # Handy in `p`/logs and in the specs that assert what got registered.
      def inspect
        "#<#{self.class.name} #{@kind} #{@wire_name.inspect} → " \
          "#{controller_name || @controller}##{@method_name}>"
      end

      private

      def resolve!
        controller = @controller.is_a?(String) ? constantize! : @controller
        return controller if controller.action_methods.include?(@method_name)

        raise Errors::VerbNotFound.new(
          "#{@kind} #{@wire_name.inspect} is no longer dispatchable",
          hint: "#{controller_name || controller}##{@method_name} is not a public controller action"
        )
      end

      def constantize!
        @controller.constantize
      rescue NameError
        # `verb_not_found`: nothing was addressed, and the caller should stop calling this name.
        raise Errors::VerbNotFound.new(
          "#{@kind} #{@wire_name.inspect} is registered to #{@controller}, which is not loaded",
          hint: 'the handler class was renamed or removed; restart the server after moving it'
        )
      end
    end
  end
end
