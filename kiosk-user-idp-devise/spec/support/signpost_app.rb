# frozen_string_literal: true

require "action_controller/railtie"
require "active_model"
require "devise"
require "rack/mock"
require "kiosk/user_identity_providers/devise"

# A Rails app with Devise, wired the way an operator wires the two signposts.
class SignpostApp < Rails::Application
  config.load_defaults 8.1
  config.eager_load = false
  config.hosts.clear
  config.secret_key_base = "signpost-spec"
  config.logger = Logger.new(IO::NULL)
  config.action_dispatch.show_exceptions = :none
end

class ApplicationController < ActionController::Base
  include Kiosk::UserIdentityProviders::Devise::WireSignpost
end

class SignpostProbesController < ApplicationController
  def create = head(:ok)
end

class User
  include ActiveModel::Model
  include ActiveModel::Validations::Callbacks
  extend ActiveModel::Callbacks
  define_model_callbacks :update
  extend Devise::Models

  devise :database_authenticatable

  def self.find_for_authentication(_conditions) = nil
end

SignpostApp.initialize!
SignpostApp.routes.draw do
  devise_for :users, controllers: { sessions: "kiosk/user_identity_providers/devise/sessions" }
  post "/probe", to: "signpost_probes#create"
end

module SignpostRequests
  JSON_CALLER = { "CONTENT_TYPE" => "application/json", "HTTP_ACCEPT" => "application/json" }.freeze
  BROWSER     = { "HTTP_ACCEPT" => "text/html" }.freeze

  def dispatch(verb, path, headers, input: "")
    Rack::MockRequest.new(SignpostApp).request(verb, "http://shop.example#{path}", headers.merge(input:))
  end
end
