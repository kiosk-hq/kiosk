# frozen_string_literal: true

require "kiosk/server/errors"

module Kiosk
  module Server
    # THE POLICY SEAM SPEAKS ONE VOCABULARY, AND THE OTHER SPELLING IS A LOAD
    # ERROR RATHER THAN A SILENT NO-OP.
    #
    # There are two vocabularies in this system and exactly one of their three
    # words is shared. An operator DECLARES a handler as `kind :query` or
    # `kind :action` (Section 8.1). The reputation/PoW seam — `challenge_for`
    # and `reputation_factors` — is asked about a call in the GATE's coarse
    # vocabulary, {Executor::VERBS}: `:query`, `:run`, `:pay`. A handler
    # declared `kind :action` arrives at the seam as **`:run`**.
    #
    # Which word wins is not this file's choice to make: the normative spec
    # publishes the seam's vocabulary — protocol Section 13 ("A policy decides
    # per CALL KIND, and the write kind is named `run`") and the matching
    # paragraph of `specification.html` — so `:run` is the word, and the guard
    # below exists to make the OTHER spelling loud instead of inert.
    #
    # WHY A GUARD AT ALL. `verb == :action` inside a policy is never wrong out
    # loud: it matches nothing, so the policy returns nil, and nil is the
    # ordinary "do not toll this one" answer. No error, no log line, no failing
    # test — the toll simply never applies to writes, which is the direction
    # that matters on a defensive surface. That is why the mapping being
    # DOCUMENTED in three places was not enough.
    #
    # WHY NOT AN ALIAS. Handing the hook a value that answers `== :action` as
    # well as `== :run` would fix the `==` spelling and break the `case`
    # spelling in the same stroke — `case verb when :run` dispatches through
    # `Symbol#===`, whose receiver is the literal and whose argument is our
    # object, and we do not control that side. An alias that works for one
    # spelling and silently fails for the other is the very defect this row is
    # about, so the seam keeps handing over a plain Symbol and the wrong
    # spelling is refused at configuration time instead.
    #
    # HOW. The hook's own source is parsed (Prism) and searched for the
    # literal `:action` / `"action"` used as a COMPARISON operand — `==`,
    # `!=`, `eql?`, `equal?`, a `when` clause, or an element of an array
    # literal that `include?` is called on. A bare `:action` elsewhere (a hash
    # key, a comment, a string in a message) is NOT flagged: a false load error
    # on a correct policy would be worse than the thing being prevented.
    #
    # WHAT IT CANNOT SEE, stated rather than hidden. If the hook's source file
    # is unreadable, if the object does not answer the hook at all, or if Prism
    # is absent (it is stdlib from Ruby 3.3 and this gem supports 3.2), the
    # check returns `:unreadable` and nothing is raised. That is a degradation,
    # not a second answer — and it is exactly what the `:clean` return value is
    # for: `verb_vocabulary_spec.rb` asserts that a well-formed policy comes
    # back `:clean`, so a parser that silently stopped reading anything turns
    # that example red rather than turning the guard into a no-op.
    module VerbVocabulary
      # The seam's name for the write kind — the word the spec publishes.
      WRITE_KIND = :run

      # The DECLARATION vocabulary's name for the same thing, which the seam
      # never hands over and which a policy must therefore not branch on.
      DECLARATION_ALIAS = :action

      # Comparison call names whose operands are checked for the alias.
      COMPARISONS = %i[== != eql? equal?].freeze

      # Raise when `target`'s `method_name` hook branches on the declaration
      # spelling of the write kind.
      #
      # @param target [Object, Proc] the policy object, or the factors lambda
      # @param method_name [Symbol, nil] the hook to inspect; nil when `target`
      #   is itself the callable
      # @param label [String] how to name the seam in the error message
      # @return [:clean, :unreadable] `:clean` when the hook was parsed and
      #   carries no alias branch; `:unreadable` when there was nothing to read
      # @raise [Errors::ConfigurationError] when the hook branches on `:action`
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

      # @return [Array(String, Integer), nil]
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

      # The outermost construct that STARTS on the hook's source line — a
      # `def`, a `->`, or the call a block hangs off. Widest span wins, so a
      # one-line hook and a multi-line one resolve the same way.
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
