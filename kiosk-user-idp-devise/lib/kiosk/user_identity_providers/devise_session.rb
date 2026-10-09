# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Kiosk
  module UserIdentityProviders
    # Signs a human in to a Devise origin through its real form and keeps the
    # session cookie; `session: true` on a call sends that cookie, so an
    # assistant's own Bearer calls never carry it.
    class DeviseSession
      # Raised when the sign-in handshake does not reach a signed-in session.
      class SignInError < StandardError; end

      attr_reader :server, :cookies

      def initialize(server)
        @server  = server.to_s.sub(%r{/\z}, "")
        @uri     = URI(@server)
        @cookies = {}
      end

      # Raises SignInError unless Devise answers the form with a redirect.
      def sign_in!(email:, password:)
        form = get_html("/users/sign_in")
        raise SignInError, "sign-in form: #{form.code}" unless form.code.to_i == 200

        res = post_form("/users/sign_in",
                        "authenticity_token" => csrf_token(form.body),
                        "user[email]"        => email,
                        "user[password]"     => password)
        raise SignInError, "sign-in failed: #{res.code}" unless [302, 303].include?(res.code.to_i)

        self
      end

      # End the session the way the browser does (Devise's DELETE /users/sign_out).
      def sign_out!
        req = Net::HTTP::Delete.new(uri_for("/users/sign_out"))
        req["Cookie"] = cookie_header unless @cookies.empty?
        request(req)
      end

      # GET an HTML page over the session (cookies attached — this is the human).
      def get_html(path)
        req = Net::HTTP::Get.new(uri_for(path))
        req["Cookie"] = cookie_header unless @cookies.empty?
        request(req)
      end

      # POST a form over the session (cookies attached — this is the human).
      def post_form(path, form, headers = {})
        req = Net::HTTP::Post.new(uri_for(path), headers)
        req["Cookie"] = cookie_header unless @cookies.empty?
        req.set_form_data(form)
        request(req)
      end

      # `session: true` in the headers sends the human's cookies.
      def post_json(path, body, headers = {})
        headers = headers.dup
        session = headers.delete(:session)
        req = Net::HTTP::Post.new(uri_for(path), { "Content-Type" => "application/json" }.merge(headers))
        req["Cookie"] = cookie_header if session
        req.body = JSON.generate(body)
        parsed(request(req))
      end

      # `session: true` in the headers sends the human's cookies.
      def get_json(path, params = {}, headers = {})
        headers = headers.dup
        session = headers.delete(:session)
        uri = uri_for(path)
        uri.query = URI.encode_www_form(params) unless params.empty?
        req = Net::HTTP::Get.new(uri, headers)
        req["Cookie"] = cookie_header if session
        parsed(request(req))
      end

      # The CSRF token Rails embeds in a rendered form.
      def csrf_token(html)
        html[/name="authenticity_token" value="([^"]+)"/, 1]
      end

      def cookie_header = @cookies.map { |k, v| "#{k}=#{v}" }.join("; ")

      # Sends a request built by the caller, absorbing every Set-Cookie; TLS follows the target's scheme.
      def request(req)
        target = req.uri || @uri
        http = Net::HTTP.new(target.host, target.port)
        http.use_ssl = target.scheme == "https"
        res = http.request(req)
        Array(res.get_fields("set-cookie")).each do |line|
          name, value = line.split(";").first.split("=", 2)
          @cookies[name] = value
        end
        res
      end

      private

      def uri_for(path)
        path.to_s.start_with?("http") ? URI(path) : URI("#{@server}#{path}")
      end

      def parsed(res)
        [res.code.to_i, (JSON.parse(res.body) rescue {})]
      end
    end
  end
end
