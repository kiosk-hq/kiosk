# frozen_string_literal: true

require "kiosk/server/errors"

module Kiosk
  module Server
    # A policy hook is asked about writes as `:run` (§13), never `:action`, and
    # a branch on `:action` would silently toll nothing. Refuses one at load by
    # parsing the hook's source; returns `:unreadable` when it cannot.
    module VerbVocabulary
      WRITE_KIND = :run

      DECLARATION_ALIAS = :action

      COMPARISONS = %i[== != eql? equal?].freeze

      # `method_name` nil when `target` is itself the callable.
      def self.assert!(target, method_name, label)
        location = source_location_for(target, method_name)
        return :unreadable if location.nil?

        node = hook_node(location)
        return :unreadable if node.nil?

        return :clean unless alias_branch?(node)

        file, line = location
        raise Errors::ConfigurationError,
              "Kiosk::Server: #{label} branches on :#{DECLARATION_ALIAS}, which this hook never " \
              "receives (#{file}:#{line}). The gate hands it one of " \
              "Kiosk::Server::Executor::VERBS — #{Executor::VERBS.map(&:inspect).join(', ')} — in which a " \
              "handler declared `kind :#{DECLARATION_ALIAS}` arrives as :#{WRITE_KIND}. Branch on " \
              ":#{WRITE_KIND}. (Protocol Section 13, Reputation.) A branch on :#{DECLARATION_ALIAS} " \
              "would match nothing and silently decline to toll every write."
      end

      def self.source_location_for(target, method_name)
        callable =
          if method_name.nil?
            target
          elsif target.respond_to?(method_name)
            target.method(method_name)
          end
        return nil if callable.nil?
        return nil unless callable.respond_to?(:source_location)

        location = callable.source_location
        return nil unless location.is_a?(Array) && location[0].is_a?(String) && location[1].is_a?(Integer)
        return nil unless File.readable?(location[0])

        location
      end
      private_class_method :source_location_for

      # The widest construct starting on the hook's source line.
      def self.hook_node(location)
        file, line = location
        tree = parse(file)
        return nil if tree.nil?

        best = nil
        walk(tree) do |node|
          next unless node.location.start_line == line
          next if best && node.location.end_line <= best.location.end_line

          best = node
        end
        best
      end
      private_class_method :hook_node

      def self.parse(file)
        @parsed ||= {}
        mtime =
          begin
            File.mtime(file)
          rescue StandardError
            nil
          end
        key = [file, mtime]
        return @parsed[key] if @parsed.key?(key)

        @parsed[key] =
          begin
            require "prism"
            result = Prism.parse_file(file)
            result.success? ? result.value : nil
          rescue LoadError, StandardError
            nil
          end
      end
      private_class_method :parse

      def self.walk(node, &block)
        return if node.nil?

        block.call(node)
        node.compact_child_nodes.each { |child| walk(child, &block) }
      end
      private_class_method :walk

      def self.alias_branch?(node)
        found = false
        walk(node) do |candidate|
          next if found

          found = true if comparison_against_alias?(candidate) ||
                          when_clause_against_alias?(candidate) ||
                          inclusion_against_alias?(candidate)
        end
        found
      end
      private_class_method :alias_branch?

      def self.comparison_against_alias?(node)
        return false unless node.is_a?(Prism::CallNode)
        return false unless COMPARISONS.include?(node.name)

        operands = [node.receiver, *(node.arguments&.arguments || [])]
        operands.any? { |operand| alias_literal?(operand) }
      end
      private_class_method :comparison_against_alias?

      def self.when_clause_against_alias?(node)
        return false unless node.is_a?(Prism::WhenNode)

        node.conditions.any? { |condition| alias_literal?(condition) }
      end
      private_class_method :when_clause_against_alias?

      def self.inclusion_against_alias?(node)
        return false unless node.is_a?(Prism::CallNode)
        return false unless %i[include? member? exclude?].include?(node.name)

        candidates = []
        candidates.concat(node.receiver.elements) if node.receiver.is_a?(Prism::ArrayNode)
        (node.arguments&.arguments || []).each do |argument|
          candidates.concat(argument.elements) if argument.is_a?(Prism::ArrayNode)
          candidates << argument
        end
        candidates.any? { |candidate| alias_literal?(candidate) }
      end
      private_class_method :inclusion_against_alias?

      def self.alias_literal?(node)
        case node
        when Prism::SymbolNode, Prism::StringNode
          node.unescaped == DECLARATION_ALIAS.to_s
        else
          false
        end
      end
      private_class_method :alias_literal?
    end
  end
end
