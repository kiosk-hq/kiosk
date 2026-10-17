# frozen_string_literal: true

# Finds the places where a verb description routes a value to another verb.
# Two shapes are recognised:
#
#   A. prose — "<pass|send|…> <span> to <verb>[ / <verb>]…[ as <tail>]"
#   B. call  — "<verb>(arg, arg, …)"
#
# From the span, tail or argument list it collects PARAM-LIKE tokens: a token
# with an underscore, or one that some verb of the same demo declares.
module DescriptorCrossReferences
  # Verbs that introduce a "route this value onward" clause.
  TRIGGER = /\b(?:pass|passing|send|supply|provide|give|echo)\b/i

  # Identifiers that read like params but never are: Postgres/GUC helpers the
  # descriptions cite by name.
  NON_PARAM_TOKENS = %w[current_user_id current_agent_id].freeze

  IDENTIFIER = /(?<![.\w])([a-z][a-z0-9]*(?:_[a-z0-9]+)*)\b/

  # "… as `booking_id`", bounded by the sentence end and by a closing paren.
  TAIL = /\A\s*(?:\([^)]*\)\s*)?as\s+([^.;)]{0,160})/

  module_function

  # Identifier tokens of a prose span that look like params. Method-call shapes
  # (`kiosk.current_user_id`) are dropped.
  def param_like(span, known_params, verb_names)
    span.scan(IDENTIFIER).flatten.uniq.select do |token|
      (token.include?('_') || known_params.include?(token)) &&
        !NON_PARAM_TOKENS.include?(token) && !verb_names.include?(token)
    end
  end

  # Every DECLARED param name a description utters, in order. A verb name is
  # never an offence: naming the follow-on verb is the sanctioned form.
  def declared_params_named(description, declared, verb_names)
    description.scan(IDENTIFIER).flatten.uniq.select do |token|
      declared.include?(token) && !NON_PARAM_TOKENS.include?(token) && !verb_names.include?(token)
    end
  end

  # Further verb names chained onto the target with "/" or ",". Takes the text
  # after the first target and returns [names, remaining text].
  def chained_targets(rest, names)
    found = []
    while (match = rest.match(%r{\A\s*[/,]\s*`?}))
      after = rest[match.end(0)..].to_s
      hit   = names.find { |name| after.start_with?(name) }
      break unless hit

      found << hit
      rest = after[hit.length..].to_s
      rest = rest[1..].to_s if rest.start_with?('`')
    end
    [found, rest]
  end

  # Every cross-reference in `verb`'s description, as {target:, tokens:, phrase:}.
  # It scans one verb name at a time with literal matches: one alternation over
  # a lazy span backtracks badly on long descriptions.
  def cross_references(verb, by_name, known_params)
    names = by_name.keys
    description = verb[:description]
    names.flat_map do |target|
      prose_references(description, target, names, known_params) +
        call_references(description, target, names, known_params)
    end
  end

  def prose_references(description, target, names, known_params)
    description.to_enum(:scan, /\bto\s+`?#{Regexp.escape(target)}`?/).flat_map do
      prose_reference_at(description, Regexp.last_match, target, names, known_params)
    end
  end

  def prose_reference_at(description, match, target, names, known_params)
    span = trigger_span(description[0...match.begin(0)])
    return [] if span.nil?

    chained, after = chained_targets(description[match.end(0)..].to_s, names)
    tail = after[TAIL, 1].to_s
    prose_reference(span, [target] + chained, tail, param_like("#{span} #{tail}", known_params, names))
  end

  # What stands between the last trigger word and "to <verb>", within the sentence.
  def trigger_span(before)
    sentence = before[/[^.;]*\z/].to_s
    trigger  = sentence.rindex(TRIGGER)
    trigger && sentence[trigger..]
  end

  def prose_reference(span, targets, tail, tokens)
    return [] if tokens.empty?

    phrase = "…#{span.strip} to #{targets.join(' / ')}#{" as #{tail.strip}" unless tail.empty?}"
    targets.uniq.map { |target| { target: target, tokens: tokens, phrase: phrase } }
  end

  def call_references(description, target, names, known_params)
    description.scan(/\b#{Regexp.escape(target)}\(([^)]*)\)/).flatten.filter_map do |args|
      tokens = param_like(args, known_params, names)
      { target: target, tokens: tokens, phrase: "#{target}(#{args})" } unless tokens.empty?
    end
  end
end
