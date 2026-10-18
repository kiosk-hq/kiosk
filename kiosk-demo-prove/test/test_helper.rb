# frozen_string_literal: true

ENV['RAILS_ENV'] ||= 'test'
require_relative '../config/environment'
require 'rails/test_help'
require 'minitest/mock'
Dir[File.join(__dir__, 'support', '*.rb')].each { require it }
