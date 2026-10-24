# frozen_string_literal: true

require 'action_controller'

module Kiosk
  module Server
    # The base of the account holder's browser pages: a signed-in session, a
    # CSRF token from the page's own form, and the binding module served.
    class ApplicationController < ::ActionController::Base
      include AccountHolderGate
      include BindingModuleGate

      prepend_before_action :refuse_unserved_binding
    end
  end
end
