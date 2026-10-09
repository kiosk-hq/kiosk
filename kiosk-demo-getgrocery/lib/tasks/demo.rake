# frozen_string_literal: true

namespace :demo do
  desc "DROP and recreate the demo database, load the schema, seed it. Repeatable, and destructive every time: nothing already in that database survives."
  task :setup do
    # db:schema:load, not db:migrate: the tracked db/schema.rb is the schema's
    # source of truth.
    sh "bundle exec rails db:drop db:create db:schema:load db:seed"
  end

  desc <<~DESC
    Reconcile orders stuck in `paying`, against Stripe where local evidence runs out.

    A crash between a capture and the paid-flip leaves an order `paying`. This
    flips it to `paid` when a settlement row or a succeeded PaymentIntent proves
    the charge, releases the claim when Stripe says nothing was charged, and
    lists the rest as UNRESOLVED with the cart-mandate ids to check by hand.
    Set MINUTES=n for the "old enough to be stuck" cutoff (default 15).
  DESC
  task reconcile: :environment do
    minutes = Integer(ENV.fetch("MINUTES", "15"))
    result  = StuckPaying.reconcile!(
      lookup: Kiosk::PaymentProviders::Stripe::ChargeLookup.new, older_than_seconds: minutes * 60,
    )

    result[:healed].each { |id| puts "HEALED      #{id} — charge on file, status → paid" }
    result[:released].each { |id| puts "RELEASED    #{id} — Stripe charged nothing, status → created" }
    result[:unresolved].each do |row|
      puts "UNRESOLVED  #{row[:order_id]} — claimed #{row[:claimed_at]}; look up a charge whose " \
           "metadata.cart_mandate_id is one of: #{row[:cart_mandate_ids].join(", ")}"
    end
    puts "healed=#{result[:healed].size} released=#{result[:released].size} unresolved=#{result[:unresolved].size}"
  end
end
