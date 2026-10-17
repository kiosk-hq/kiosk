# frozen_string_literal: true

# Builds handler classes for specs that need a throwaway Kiosk::Handler.
module B1HandlerClasses
  OPEN_INPUT = { type: 'object', additionalProperties: false, properties: {}, required: [] }.freeze

  # Declares one verb, runs the block as the class body, and binds the class to `const`.
  # The block defines the verb method and anything the class body needs before it.
  def stub_handler(const, verb_kind, text, &)
    klass = Class.new(ApplicationController) { include Kiosk::Handler }
    declare_verb(klass, verb_kind, text)
    klass.class_eval(&)
    stub_const(const, klass)
  end

  # Declares the next verb on `klass` with an open input schema and any output.
  def declare_verb(klass, verb_kind, text)
    klass.kind(verb_kind)
    klass.description(text)
    klass.input_schema(**OPEN_INPUT)
    klass.output_schema(true)
  end
end
