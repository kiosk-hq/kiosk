# frozen_string_literal: true

require "kiosk/user_identity_providers/devise_session"

module Kiosk
  module TestHelpers
    # Someone signed in on the operator's own site: links assistants to their
    # account, approves the code an assistant shows them, and unlinks one.
    #
    #   alice = a_person(email: "alice@example.com", password: "…")
    #   diner = alice.links(a_newcomer(as: Diner))
    class Person
      # The signed-in browser session, for the operator's own pages.
      attr_reader :site

      def initialize(origin, email:, password:)
        @site = UserIdentityProviders::DeviseSession.new(origin).sign_in!(email:, password:)
      end

      # A one-time code for an assistant to redeem.
      def link_code
        status, link = site.post_json("/kiosk/auth/link", {}, { session: true })
        raise "the site minted no link code: #{status} #{link}" unless status == 201

        link.fetch("link_code")
      end

      # `customer` redeems a fresh link code, and comes back acting for this person.
      def links(customer) = customer.redeems(link_code)

      # Approves the code an assistant showed, on the site's verification page.
      def approves(user_code)
        page = site.get_html("/kiosk/oauth/device/verify?user_code=#{user_code}")
        approved = site.post_form("/kiosk/oauth/device/verify", "user_code" => user_code, "decision" => "approve",
                                                                "authenticity_token" => site.csrf_token(page.body))
        raise "the site did not approve #{user_code}: #{page.code}, #{approved.code}" unless [page.code, approved.code] == %w[200 200]
      end

      def unlinks(customer)
        status, = site.post_json("/kiosk/auth/unlink", { agent_id: customer.principal.agent_id }, { session: true })
        raise "the site did not unlink #{customer.principal.agent_id}: #{status}" unless status == 204
      end

      def visits(path) = site.get_html(path)
    end
  end
end
