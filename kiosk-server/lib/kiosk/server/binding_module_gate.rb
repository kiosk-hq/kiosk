# frozen_string_literal: true

require "kiosk/server/errors"
require "kiosk/server/headers"

module Kiosk
  module Server
    # The module check every account-binding endpoint runs first: at an origin
    # that does not serve binding (`c.serve_account_binding = false`) the path
    # answers `501 module_not_served` instead of the ceremony.
    #
    # It runs BEFORE anything about the request is read, because whether this
    # origin binds accounts at all is a fact about the ORIGIN and true of every
    # caller — the same ordering {Executor#verb_pay} gives for the payment
    # module.
    #
    # The `/oauth/*` endpoints answer the OAuth error object, and this is the
    # ONE Kiosk problem document they serve: no OAuth error means "there is no
    # device grant here to be inside of".
    module BindingModuleGate
      DETAIL = "this operator does not serve the account binding module"
      HINT   = "register a fresh assistant account at this origin's register_url instead"

      private

      # @return [void] renders the refusal, which halts the callback chain
      def refuse_unserved_binding
        return if Kiosk.configuration.serve_account_binding

        error = Errors::ModuleNotServed.new(DETAIL, hint: HINT)
        Headers.add_to(response.headers)
        Headers.add_cache_policy(response.headers, status: error.http_status)
        render json: error.to_problem, status: error.http_status,
               content_type: Errors::PROBLEM_CONTENT_TYPE
      end
    end
  end
end
