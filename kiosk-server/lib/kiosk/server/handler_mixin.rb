# frozen_string_literal: true

require "action_controller"
require "action_dispatch"
require "kiosk/server/actions"
require "kiosk/server/errors"
require "kiosk/server/failure_log"
require "kiosk/server/queries"
require "kiosk/server/handler_dispatch"

module Kiosk
  module Server
    # Implementation behind `include Kiosk::Handler`. The macros above a `def` make it a wire verb;
    # a method with no pending declaration stays off the wire.
    module HandlerMixin
      KINDS = %i[action query].freeze

      # The four reaches of §7.2; the first is the default.
      REACHES = %i[principal published consented role].freeze

      # The strictest reach, so an undeclared verb is never widened.
      DEFAULT_REACH = :principal

      # §8.1: a verb name is one path segment.
      NAME_PATTERN = /\A[a-z][a-z0-9_]*\z/

      # First path segments the engine draws under the mount; keep in step with its routes.
      RESERVED_NAMES = %w[agents auth events kyc oauth pay payment_setup request_kyc schema].freeze

      # Required on every verb (§8.3); a declaration missing either is refused at class load.
      REQUIRED_DECLARATIONS = %i[input_schema output_schema].freeze

      # Installs the mixin. Called from Kiosk::Handler.included.
      def self.install(base)
        unless base.is_a?(Class) && base <= ::ActionController::Metal
          raise ArgumentError,
            "include Kiosk::Handler into a controller class — Kiosk dispatches " \
            "handlers through Controller.action(…), which needs an ActionController subclass. " \
            "Pick the base class yourself (ApplicationController, ActionController::API, …); " \
            "Kiosk does not impose one."
        end

        # An operator's base class and its subclass may both include the mixin.
        return if base.respond_to?(:kiosk_declarations)

        base.extend(ClassMethods)
        base.include(InstanceMethods)

        # The wire authenticates by bearer token, never by cookie, so CSRF protection does not apply.
        base.skip_forgery_protection if base.respond_to?(:skip_forgery_protection)

        # A route drawn straight at a handler controller must not bypass the wire.
        base.before_action(:kiosk_require_wire_dispatch!) if base.respond_to?(:before_action)

        # Registered at include time, so an operator's own `rescue_from` declared later wins.
        base.rescue_from(StandardError, with: :kiosk_rescue_to_wire) if base.respond_to?(:rescue_from)
      end

      # Resolved lazily so this file can be required before the registries.
      def self.registry_for(kind)
        kind == :action ? Actions : Queries
      end

      # Evaluates a `topic` block, keeping its declarations out of the verb macros' pending state.
      class TopicDeclaration
        attr_reader :reach_value, :description_value, :payload_schema_value,
                    :subject_reachable_value

        def reach(value)
          unless REACHES.include?(value)
            raise ArgumentError,
              "a topic declared `reach #{value.inspect}`, which is not a Kiosk reach. " \
              "It is :principal (the default — only the calling principal's own events), " \
              ":published (the operator publishes to everyone, by intent), :consented (a " \
              "principal shared the subject, and the operator can point at the artefact " \
              "that says so) or :role (the reach follows the caller's operator-assigned " \
              "role claim)."
          end

          @reach_value = value
        end

        def description(text)
          declared << :description
          @description_value = text
        end

        def payload_schema(schema = nil, **kwargs)
          declared << :payload_schema
          @payload_schema_value = schema || kwargs
        end

        # `(subject, identity) -> Boolean`; runs outside any request, so it cannot read {CurrentRequest}.
        def subject_reachable(callable) = @subject_reachable_value = callable

        # Each macro must be called; `description nil` is a valid answer (§8.5.1).
        def validate!(owner:, name:)
          missing = Events::REQUIRED - declared
          return if missing.empty?

          raise ArgumentError,
            "#{owner} declared `topic #{name.inspect}` without " \
            "#{missing.join(" and ")}. A topic carries `description` for semantics and " \
            "`payload_schema` for shape; a subscriber with neither has to receive a " \
            "message to find out what it is."
        end

        private

        def declared = (@declared ||= [])
      end

      module ClassMethods
        # Which HTTP method reaches the next-defined method; one controller may declare both.
        def kind(value)
          unless KINDS.include?(value)
            raise ArgumentError,
              "#{self} declared `kind #{value.inspect}`, which is not a Kiosk verb kind. " \
              "It is :query (reached by GET #{Kiosk.configuration.mount_path}/<name>) or " \
              ":action (POST #{Kiosk.configuration.mount_path}/<name>)."
          end

          kiosk_pending[:kind] = value
        end

        # Whose rows the next verb may touch (§7.2); the default is :principal.
        def reach(value)
          unless REACHES.include?(value)
            raise ArgumentError,
              "#{self} declared `reach #{value.inspect}`, which is not a Kiosk verb reach. " \
              "It is :principal (the default — only the calling principal's own rows, or rows " \
              "that belong to no principal), :published (the operator publishes owner-carrying " \
              "rows to everyone, by intent), :consented (a principal shared them, and the " \
              "operator can point at the artefact that says so) or :role (the reach follows the " \
              "caller's operator-assigned role claim). A verb that touches nobody else's rows " \
              "declares nothing at all."
          end

          kiosk_pending[:reach] = value
        end

        def description(text)
          kiosk_pending[:description] = text
        end

        def input_schema(schema = nil, **kwargs)
          kiosk_pending[:input_schema] = schema || kwargs
        end

        def output_schema(schema = nil, **kwargs)
          kiosk_pending[:output_schema] = schema || kwargs
        end

        def example_params(example = nil, **kwargs)
          kiosk_pending[:example_params] = example || kwargs
        end

        def example_row(example = nil, **kwargs)
          kiosk_pending[:example_row] = example || kwargs
        end

        def wire_name(name)
          kiosk_pending[:wire_name] = name.to_s
        end

        # Declares an event topic; the block holds `reach`, `description`, `payload_schema` and `subject_reachable`.
        def topic(name, &block)
          name = name.to_s

          unless name.match?(NAME_PATTERN)
            raise ArgumentError,
              "#{self} declared `topic #{name.inspect}`, which is not a legal Kiosk name. " \
              "A topic name is a wire name: #{NAME_PATTERN.inspect}."
          end

          if RESERVED_NAMES.include?(name)
            raise ArgumentError,
              "#{self} declared `topic #{name.inspect}`, but that name is reserved by the " \
              "engine itself: #{RESERVED_NAMES.join(", ")}. Give the topic a name of its own."
          end

          declaration = TopicDeclaration.new
          declaration.instance_eval(&block) if block
          declaration.validate!(owner: self, name: name)

          kiosk_topic_declarations[name] = {
            name: name,
            reach: declaration.reach_value || :principal,
            description: declaration.description_value,
            payload_schema: declaration.payload_schema_value,
            subject_reachable: declaration.subject_reachable_value,
          }
        end

        # `super` first: AbstractController::Base also hooks method_added.
        def method_added(method_name)
          super
          pending = @kiosk_pending
          return if pending.nil? || pending.empty?

          @kiosk_pending = nil
          kiosk_declare(method_name, pending)
        end

        # Wire name → declaration for the verbs on this class, one per name.
        def kiosk_declarations
          @kiosk_declarations ||= {}
        end

        # Wire name → declaration for the topics on this class.
        def kiosk_topic_declarations
          @kiosk_topic_declarations ||= {}
        end

        # Runs as the class body is read; call it directly only to restore registrations after a test reset.
        def kiosk_register!
          kiosk_declarations.each_value { |declaration| kiosk_register_one(declaration) }
          kiosk_topic_declarations.each_value { |declaration| Events.register(**declaration) }
          self
        end

        private

        def kiosk_pending
          @kiosk_pending ||= {}
        end

        def kiosk_declare(method_name, pending)
          declaration = pending.merge(
            method_name: method_name.to_s,
            wire_name:   (pending[:wire_name] || method_name).to_s,
            reach:       pending[:reach] || HandlerMixin::DEFAULT_REACH,
          )
          kiosk_refuse_bad_declaration!(declaration)
          kiosk_declarations[declaration[:wire_name]] = declaration
          kiosk_register_one(declaration)
        end

        # The §8.1/§8.3 name rules and required fields, refused at class load.
        def kiosk_refuse_bad_declaration!(declaration)
          name = declaration[:wire_name]
          where = "#{self}##{declaration[:method_name]}"

          if declaration[:kind].nil?
            raise ArgumentError,
              "#{where} declares the Kiosk verb #{name.inspect} without a `kind`. Every " \
              "declaration says which verb reaches it: `kind :query` is served at " \
              "GET #{Kiosk.configuration.mount_path}/#{name}, `kind :action` at " \
              "POST #{Kiosk.configuration.mount_path}/#{name}. One controller may declare " \
              "both — the kind belongs to the declaration, not to the class — so there is " \
              "no default to fall back on."
          end

          # One name declared twice in one class body; the cross-class case is {HandlerRegistrations}.
          clash = kiosk_declarations[name]
          if clash && clash[:kind] != declaration[:kind]
            raise ArgumentError,
              "#{where} declares #{name.inspect} as a#{declaration[:kind] == :action ? "n" : ""} " \
              "#{declaration[:kind]}, but ##{clash[:method_name]} on this class already " \
              "declares it as a#{clash[:kind] == :action ? "n" : ""} #{clash[:kind]}. A verb " \
              "name is one path segment and one kind: " \
              "GET #{Kiosk.configuration.mount_path}/#{name} and " \
              "POST #{Kiosk.configuration.mount_path}/#{name} cannot reach different handlers. " \
              "Rename one, or give it a `wire_name` of its own."
          elsif clash
            raise ArgumentError,
              "#{where} declares the Kiosk verb #{name.inspect}, which ##{clash[:method_name]} " \
              "on this class already declares. A verb name is ONE path segment reaching ONE " \
              "method: storing the second would replace the first, " \
              "#{Kiosk.configuration.mount_path}/#{name} would reach " \
              "##{declaration[:method_name]}, and ##{clash[:method_name]} would be off the wire " \
              "with nothing to say so. Rename one of the methods, or give one of them a " \
              "`wire_name` of its own."
          end

          unless HandlerMixin::NAME_PATTERN.match?(name)
            raise ArgumentError,
              "#{where} declares the Kiosk verb #{name.inspect}, which is not a legal verb " \
              "name. A verb is ONE path segment matching #{HandlerMixin::NAME_PATTERN.source} " \
              "(spec §8.1) — lower case, starting with a letter, digits and underscores after " \
              "that. Rename the method, or give it a legal `wire_name`."
          end

          if HandlerMixin::RESERVED_NAMES.include?(name)
            raise ArgumentError,
              "#{where} declares the Kiosk verb #{name.inspect}, which is RESERVED: the engine " \
              "draws #{Kiosk.configuration.mount_path}/#{name} itself, and the mount is drawn " \
              "before your own routes, so that route wins by first-match — the verb would never " \
              "be reached. Reserved: " \
              "#{HandlerMixin::RESERVED_NAMES.join(", ")}. Give it a `wire_name` of its own."
          end

          missing = HandlerMixin::REQUIRED_DECLARATIONS.reject { |key| declaration.key?(key) }
          return if missing.empty?

          raise ArgumentError,
            "#{where} declares the Kiosk verb #{name.inspect} without #{missing.join(" and ")}. " \
            "Both are REQUIRED on every verb: `input_schema` is the contract the wire " \
            "coerces and validates arguments against, and `output_schema` is the only " \
            "machine-readable statement of what the call returns now that the response " \
            "envelope is gone. A verb that takes nothing still declares " \
            "`input_schema type: \"object\", additionalProperties: false, properties: {}, " \
            "required: []`."
        end

        def kiosk_register_one(declaration)
          handler = HandlerDispatch.new(
            controller:  self,
            method_name: declaration[:method_name],
            wire_name:   declaration[:wire_name],
            kind:        declaration[:kind],
          )
          HandlerMixin.registry_for(declaration[:kind]).declare(
            declaration[:wire_name], handler,
            reach:          declaration[:reach],
            description:    declaration[:description],
            input_schema:   declaration[:input_schema],
            output_schema:  declaration[:output_schema],
            example_params: declaration[:example_params],
            example_row:    declaration[:example_row],
          )
        end
      end

      # Handler-side helpers, private so none is mistaken for a controller action.
      module InstanceMethods
        private

        # The acting {Kiosk::Identity}; nil outside a wire request.
        def kiosk_identity
          request.env[HandlerDispatch::IDENTITY_KEY]
        end

        # Differs from the method name only under `wire_name`.
        def kiosk_wire_name
          request.env[HandlerDispatch::DISPATCH_KEY]
        end

        # One page of rows; a nil `next_cursor` is the last page. `total` counts every matching row and
        # nil omits `X-Total-Count`. The body stays the bare rows; the page facts leave as headers.
        def render_kiosk_page(rows, next_cursor: nil, total: nil)
          request.env[HandlerDispatch::PAGE_KEY] = true
          render json: { rows: rows, next_cursor: next_cursor, total: total }
        end

        # A validation failure answers 400 with the errors' full messages. Any other raise Rails knows
        # a status for maps to its lone wire code, its own message going to the operator's log and
        # never onto the wire; anything else is re-raised.
        def kiosk_rescue_to_wire(exception)
          raise exception if exception.is_a?(Kiosk::Server::Errors::Base)

          invalid = kiosk_invalid_model(exception)
          raise Kiosk::Server::Errors::BadRequest, invalid.errors.full_messages.join("; ") if invalid

          status = ::ActionDispatch::ExceptionWrapper.rescue_responses[exception.class.name]
          code   = Kiosk::Server::Errors::STATUS_CODES[::Rack::Utils.status_code(status)]
          raise exception if code.nil?

          Kiosk::Server::FailureLog.report(
            "verb #{kiosk_wire_name.inspect} answered #{code} for #{exception.class}", exception
          )

          # Reaches the audit sink as `cause`; never part of the problem document.
          request.env[HandlerDispatch::RESCUED_KEY] = exception

          render json: {
            ok:    false,
            error: Kiosk::Server::Errors.rescued_wire(code, verb: kiosk_wire_name),
          }, status: Kiosk::Server::Errors::CODES.fetch(code)
        end

        # A failed model validation is an argument outside its domain: 400, in the model's own words.
        def kiosk_invalid_model(exception)
          case exception
          when ::ActiveModel::ValidationError then exception.model
          when ::ActiveRecord::RecordInvalid  then exception.record
          end
        end

        # A route drawn straight at a handler controller answers 404 `verb_not_found`.
        def kiosk_require_wire_dispatch!
          return if request.env.key?(HandlerDispatch::DISPATCH_KEY)

          problem = Kiosk::Server::Errors::VerbNotFound.new(
            "Kiosk handlers are reachable through the Kiosk wire only",
            hint: "call the verb's own route — " \
                  "GET #{Kiosk.configuration.mount_path}/<query-name> or " \
                  "POST #{Kiosk.configuration.mount_path}/<action-name>",
          ).to_problem

          render json:         problem,
                 status:       :not_found,
                 content_type: Kiosk::Server::Errors::PROBLEM_CONTENT_TYPE
        end
      end
    end
  end
end
