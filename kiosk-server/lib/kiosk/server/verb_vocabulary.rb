# frozen_string_literal: true

require 'kiosk/server/errors'

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
        location = HookSource.location_for(target, method_name)
        return :unreadable if location.nil?

        node = HookSource.node_at(*location)
        return :unreadable if node.nil?

        return :clean unless alias_branch?(node)

        raise Errors::ConfigurationError, alias_branch_message(label, *location)
      end

      def self.alias_branch_message(label, file, line)
        "Kiosk::Server: #{label} branches on :#{DECLARATION_ALIAS}, which this hook never " \
          "receives (#{file}:#{line}). The gate hands it one of " \
          "Kiosk::Server::Executor::VERBS — #{Executor::VERBS.map(&:inspect).join(', ')} — in which a " \
          "handler declared `kind :#{DECLARATION_ALIAS}` arrives as :#{WRITE_KIND}. Branch on " \
          ":#{WRITE_KIND}. (Protocol Section 13, Reputation.) A branch on :#{DECLARATION_ALIAS} " \
          'would match nothing and silently decline to toll every write.'
      end
      private_class_method :alias_branch_message

      def self.alias_branch?(node)
        found = false
        HookSource.walk(node) do |candidate|
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

        inclusion_candidates(node).any? { |candidate| alias_literal?(candidate) }
      end
      private_class_method :inclusion_against_alias?

      # The receiver's array elements, then each argument and its array elements.
      def self.inclusion_candidates(node)
        candidates = node.receiver.is_a?(Prism::ArrayNode) ? node.receiver.elements.dup : []
        (node.arguments&.arguments || []).each do |argument|
          candidates.concat(argument.elements) if argument.is_a?(Prism::ArrayNode)
          candidates << argument
        end
        candidates
      end
      private_class_method :inclusion_candidates

      def self.alias_literal?(node)
        case node
        when Prism::SymbolNode, Prism::StringNode
          node.unescaped == DECLARATION_ALIAS.to_s
        else
          false
        end
      end
      private_class_method :alias_literal?

      # Finds a hook's source and parses it; every answer is nil when it cannot.
      module HookSource
        module_function

        def location_for(target, method_name)
          callable = callable_for(target, method_name)
          return nil unless callable.respond_to?(:source_location)

          readable_location(callable.source_location)
        end

        def callable_for(target, method_name)
          return target if method_name.nil?

          target.method(method_name) if target.respond_to?(method_name)
        end

        # `[file, line]` when the file can be read.
        def readable_location(location)
          return nil unless location.is_a?(Array) && location[0].is_a?(String) && location[1].is_a?(Integer)

          location if File.readable?(location[0])
        end

        # The widest construct starting on the hook's source line.
        def node_at(file, line)
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

        def parse(file)
          @parsed ||= {}
          key = [file, mtime_of(file)]
          return @parsed[key] if @parsed.key?(key)

          @parsed[key] = parse_tree(file)
        end

        def mtime_of(file)
          File.mtime(file)
        rescue StandardError
          nil
        end

        def parse_tree(file)
          require 'prism'
          result = Prism.parse_file(file)
          result.success? ? result.value : nil
        rescue LoadError, StandardError
          nil
        end

        def walk(node, &block)
          return if node.nil?

          block.call(node)
          node.compact_child_nodes.each { |child| walk(child, &block) }
        end
      end
    end
  end
end
