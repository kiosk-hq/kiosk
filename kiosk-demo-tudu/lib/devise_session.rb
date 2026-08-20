# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

# The ONE way a demo driver obtains a HUMAN principal.
#
# Every demo authenticates its humans with real Devise (T-066): there is no
# stub user-IdP left to hand a driver a synthetic `user:u-<uuid>` bearer. So a
# driver that needs the human half of a ceremony — approving an assistant on
# the device-verify page, minting a link code, unlinking — has to hold a real
# browser session, and that means the real form: GET /users/sign_in for the
# cookie and the CSRF token, POST the credentials, keep the Set-Cookie.
#
# That handshake was written out inline in every driver that needed it, which
# is how a mechanism becomes seven mechanisms. It is one object here, hand-
# copied across the demos and held byte-identical by bin/check-demo-copies.
#
# Nothing in it is a test double: it drives the shipped Devise routes over real
# HTTP exactly as a browser does. `session: true` is the only knob — it marks
# the calls that are the HUMAN's (cookies attached); an agent's calls carry
# their own Bearer and must never carry the human's cookies, which is why the
# jar is opt-in per request rather than always-on.
#
#   session = DeviseSession.new(ENV.fetch("SERVER_URL"))
#   session.sign_in!(email: "alice@example.com", password: "…")
#   rc, link = session.post_json("/kiosk/auth/link", {}, { session: true })
class DeviseSession
  # Raised when the sign-in handshake does not reach a signed-in session.
  class SignInError < StandardError; end

  attr_reader :server, :cookies

  def initialize(server)
    @server  = server.to_s.sub(%r{/\z}, "")
    @uri     = URI(@server)
    @cookies = {}
  end

  # Sign a human in through the real Devise form. Returns self so callers can
  # chain; raises SignInError with the server's status when it does not take.
  def sign_in!(email:, password:)
    form = get_html("/users/sign_in")
    raise SignInError, "sign-in form: #{form.code}" unless form.code.to_i == 200

    res = post_form("/users/sign_in",
                    "authenticity_token" => csrf_token(form.body),
                    "user[email]"        => email,
                    "user[password]"     => password)
    # Devise answers a successful form sign-in with a redirect; a REJECTED one
    # re-renders the form (200), so the status is the whole assertion.
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

  # POST JSON. `session: true` in the headers Hash sends the human's cookie
  # jar; without it the call carries only what the caller passed — which is how
  # an agent's Bearer call stays an agent's call.
  def post_json(path, body, headers = {})
    headers = headers.dup
    session = headers.delete(:session)
    req = Net::HTTP::Post.new(uri_for(path), { "Content-Type" => "application/json" }.merge(headers))
    req["Cookie"] = cookie_header if session
    req.body = JSON.generate(body)
    parsed(request(req))
  end

  # GET JSON. Same rule: cookies only on `session: true`.
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

  private

  # Absorb Set-Cookie on EVERY response: Rails rotates the session cookie on
  # sign-in, and a jar that only reads the sign-in response goes stale.
  def request(req)
    res = Net::HTTP.new(@uri.host, @uri.port).request(req)
    Array(res.get_fields("set-cookie")).each do |line|
      name, value = line.split(";").first.split("=", 2)
      @cookies[name] = value
    end
    res
  end

  def uri_for(path)
    path.to_s.start_with?("http") ? URI(path) : URI("#{@server}#{path}")
  end

  def parsed(res)
    [res.code.to_i, (JSON.parse(res.body) rescue {})]
  end
end
