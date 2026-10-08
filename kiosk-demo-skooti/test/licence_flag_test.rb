# frozen_string_literal: true

require "test_helper"

# Each rental verb opens only for a `needs_licence` that casts to its literal
# boolean, so no reading of the flag opens both.
class LicenceFlagTest < ActiveSupport::TestCase
  def vehicle_reading(raw)
    Scooter.new.tap { |scooter| scooter.define_singleton_method(:needs_licence) { raw } }
  end

  test "a truthy spelling is licence-required only" do
    ["TRUE", "True", "t", "true", "yes", "y", "on", "1", 1, 2, "Y", "ON"].each do |raw|
      assert vehicle_reading(raw).licence_required?, raw.inspect
      assert_not vehicle_reading(raw).licence_free?, raw.inspect
    end
  end

  test "a falsy spelling is licence-free only" do
    [false, "f", "false", "FALSE", "0", 0, "off", "OFF"].each do |raw|
      assert vehicle_reading(raw).licence_free?, raw.inspect
      assert_not vehicle_reading(raw).licence_required?, raw.inspect
    end
  end

  test "an ambiguous flag opens neither verb" do
    [nil, ""].each do |raw|
      assert_not vehicle_reading(raw).licence_free?, raw.inspect
      assert_not vehicle_reading(raw).licence_required?, raw.inspect
    end
  end

  test "the column itself" do
    assert Scooter.new(needs_licence: true).licence_required?
    assert Scooter.new(needs_licence: false).licence_free?
  end

  test "each rental verb gates on its predicate, never on the raw column" do
    { "start_rental_operation.rb" => "licence_free?", "rent_motorcycle_operation.rb" => "licence_required?" }.each do |file, predicate|
      code = Rails.root.join("app/operations", file).read.lines.grep_v(/\A\s*#/).join
      assert_includes code, predicate, file
      assert_no_match(/\bneeds_licence\b/, code, file)
    end
  end
end
