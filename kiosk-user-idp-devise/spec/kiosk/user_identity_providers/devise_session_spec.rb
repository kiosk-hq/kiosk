# frozen_string_literal: true

require 'kiosk/user_identity_providers/devise_session'
require_relative '../../support/stub_devise_app'

# The client half, driven over a real socket: the subject drives the shipped
# Devise routes over real HTTP exactly as a browser does.
RSpec.describe Kiosk::UserIdentityProviders::DeviseSession, '#sign_in! when Devise takes the credentials' do
  include_context 'with a stub Devise app'

  let(:responder) do
    lambda do |request|
      if request.verb == 'GET'
        [200, ['Set-Cookie: _demo_session=first; path=/'], sign_in_form]
      else
        [302, ['Location: /', 'Set-Cookie: _demo_session=rotated; path=/'], '']
      end
    end
  end

  it 'drives the real form, carries the CSRF token and keeps the rotated cookie' do
    expect(session.sign_in!(email: 'alice@example.com', password: 's3cret')).to be(session)

    form, post = app.requests
    expect([form.verb, form.path]).to eq(['GET', '/users/sign_in'])
    expect([post.verb, post.path]).to eq(['POST', '/users/sign_in'])
    expect(post.body).to include('authenticity_token=tok-42')
    expect(post.body).to include('alice%40example.com')
    # The jar the form handed out goes back up with the POST...
    expect(post.headers['cookie']).to include('_demo_session=first')
    # ...and Rails rotates it on sign-in, which a jar that only read the
    # form response would miss.
    expect(session.cookies).to eq('_demo_session' => 'rotated')
  end
end

RSpec.describe Kiosk::UserIdentityProviders::DeviseSession, '#sign_in! when the sign-in page does not render' do
  include_context 'with a stub Devise app'

  let(:responder) { ->(_request) { [500, [], 'boom'] } }

  it 'raises SignInError naming the status' do
    expect { session.sign_in!(email: 'alice@example.com', password: 's3cret') }
      .to raise_error(described_class::SignInError, 'sign-in form: 500')
  end
end

RSpec.describe Kiosk::UserIdentityProviders::DeviseSession, '#sign_in! when Devise re-renders the form' do
  include_context 'with a stub Devise app'

  # A rejected sign-in answers 200 with the form again, not an error status,
  # so the check is on the status rather than on a 2xx/5xx split.
  let(:responder) { ->(_request) { [200, [], sign_in_form] } }

  it 'raises SignInError rather than reporting a signed-in session' do
    expect { session.sign_in!(email: 'alice@example.com', password: 'wrong') }
      .to raise_error(described_class::SignInError, 'sign-in failed: 200')
  end
end

RSpec.describe Kiosk::UserIdentityProviders::DeviseSession, '#request' do
  it 'dials an IPv6 literal origin by its bare address' do
    dialed = []
    response = Net::HTTPOK.new('1.1', '200', 'OK')
    allow_any_instance_of(Net::HTTP).to receive(:request) { |http, _req| (dialed << http) && response }

    described_class.new('http://[::1]:3000').request(Net::HTTP::Get.new(URI('http://[::1]:3000/users/sign_in')))

    expect([dialed.first.address, dialed.first.port]).to eq(['::1', 3000])
  end
end
