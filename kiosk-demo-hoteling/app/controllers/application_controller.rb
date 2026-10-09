# frozen_string_literal: true

class ApplicationController < ActionController::Base
  include Kiosk::UserIdentityProviders::Devise::WireSignpost
end
