# frozen_string_literal: true

require "kiosk/server/errors"
require "kiosk/server/headers"

module Kiosk
  module Server
    # Answers `501 module_not_served` on every account-binding endpoint when
    # `c.serve_account_binding` is false. Runs before the request is read; on
    # `/oauth/*` it is the one problem document served instead of an OAuth error.
    module BindingModuleGate
      DETAIL = "this operator does not serve the account binding module"
      HINT   = "register a fresh assistant account at this origin's register_url instead"

      private

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
