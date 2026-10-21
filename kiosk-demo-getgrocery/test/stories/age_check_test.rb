# frozen_string_literal: true

require 'test_helper'
require 'kiosk/test_helpers/kyc'

class AgeCheckStory < StoryTest
  include Kiosk::TestHelpers::Kyc

  test 'a shopper buys wine once a verification service confirms they are over 18' do
    shopper = a_shopper

    refused = shopper.orders('table-red-wine')

    assert_refused refused, :kyc_required
    assert_includes refused.hint, 'request_kyc'

    shopper.requests_verification
    the_verification_service_confirms(shopper, 'age_over_18' => true)

    assert shopper.hears_verification_passed

    wine = shopper.orders('table-red-wine')

    assert_predicate wine, :ok?, wine
    assert_predicate shopper.pays_for(wine), :ok?
  end

  test 'groceries with no age restriction need no age check' do
    assert_predicate a_shopper.orders('banana'), :ok?
  end

  test 'an attestation the verification service did not sign proves nothing' do
    shopper = a_shopper
    claims, = JWT.decode(kyc_attestation(shopper.principal, 'age_over_18' => true), nil, false)
    forged = JWT.encode(claims, OpenSSL::PKey.generate_key('ED25519'), 'EdDSA')

    assert shopper.presents(forged).refused?(:forbidden)
    assert shopper.orders('table-red-wine').refused?(:kyc_required)
  end

  test 'an attestation that spells the answer any other way than true proves nothing' do
    shopper = a_shopper

    assert_predicate shopper.presents(kyc_attestation(shopper.principal, 'age_over_18' => true)), :ok?
    assert_predicate shopper.orders('table-red-wine'), :ok?

    assert_predicate shopper.presents(kyc_attestation(shopper.principal, 'age_over_18' => 'true')), :ok?
    assert shopper.orders('table-red-wine').refused?(:kyc_required)
  end
end
