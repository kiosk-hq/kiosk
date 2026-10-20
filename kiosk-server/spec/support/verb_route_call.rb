# frozen_string_literal: true

require 'json'
require 'rack/mock'
require 'uri'

# A verb call through the route `kiosk do` draws, as the router reaches it. The
# wire resolves the example's `identity` as the caller, and the session runs on
# its `connection`.
module VerbRouteCall
  # What the wire answered: the parsed body (nil when empty), its status and headers.
  Answer = Data.define(:status, :body, :headers) do
    # The answer a Rack triple carries.
    def self.from((status, headers, body))
      raw = +''
      body.each { |chunk| raw << chunk }
      new(status: status, body: raw.empty? ? nil : JSON.parse(raw), headers: headers)
    end

    def ok? = (200...300).cover?(status)

    # The `cursor` of the `Link: rel="next"` target, or nil on the last page.
    def next_cursor
      target = headers['Link'].to_s[/<([^>]*)>\s*;\s*rel="next"/, 1]
      target && URI.decode_www_form(URI(target).query).to_h['cursor']
    end
  end

  # `kind` is :query or :action; a query's arguments ride in the query string, an action's in the body.
  # `env` adds Rack env entries, such as request headers.
  def call_verb_route(kind, name, args = {}, **env)
    allow(Kiosk::Server::IdentityResolution).to receive(:resolve).and_return(identity)
    allow(ActiveRecord::Base).to receive(:lease_connection).and_return(connection)
    Answer.from(Kiosk::Server::Routing::VerbRoute.new(kind, name.to_s).call(verb_route_env(kind, name, args).merge(env)))
  end

  # The answer's body on a 2xx; otherwise the wire error its problem document names.
  def verb_answer(kind, name, args = {}, **)
    answer = call_verb_route(kind, name, args, **)
    return answer if answer.ok?

    problem = answer.body
    raise Kiosk::Server::Errors::WireError.new(
      problem['detail'], code: problem['code'], hint: problem['hint'],
                         extra: problem.except('type', 'title', 'status').transform_keys(&:to_sym)
    )
  end

  private

  def verb_route_env(kind, name, args)
    if kind == :query
      query = args.empty? ? '' : "?#{URI.encode_www_form(args)}"
      Rack::MockRequest.env_for("https://provider.example/kiosk/#{name}#{query}", method: 'GET')
    else
      Rack::MockRequest.env_for("https://provider.example/kiosk/#{name}", method: 'POST', input: JSON.generate(args),
                                                                          'CONTENT_TYPE' => 'application/json')
    end
  end
end
