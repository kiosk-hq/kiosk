# frozen_string_literal: true

# A fleet vehicle. `name` and `dock` make it concrete (e.g. "Amstel Cruiser"
# at "Amstel Garage"); `kind` distinguishes the licence-free electric scooter
# ('scooter') from a combustion-engine motorcycle ('motorcycle'); when
# `needs_licence` is true, renting it is KYC-gated (age_over_18 AND licence_a)
# via the `rent_motorcycle` Action. Licence-free scooters use `start_rental`.
class Scooter < ApplicationRecord
  AVAILABLE = "available"

  has_many :reservations, dependent: :destroy

  # The fleet `scooters_available` publishes.
  scope :available, -> { where(status: AVAILABLE) }

  # ── THE licence predicate, in the ONE place both rental verbs read it ──────
  #
  # K-687 is the finding that the licence gate was one verb name away from
  # being optional: `reserve` is open to every vehicle (one reservation shape,
  # both verbs), so before the gate existed an agent reserved the KYC-gated
  # motorcycle and activated it through the licence-FREE verb, and got a signed
  # unlock token having attested nothing. The check therefore lives at USE time
  # in BOTH verbs — and because it does, the two readings of this one column
  # must not be able to drift apart. They are these two methods.
  #
  # K-724 is why the cast is here at all rather than a bare `needs_licence`.
  # The check used to enumerate the truthy spellings it knew by hand
  # (`== true || == "t" || == "true"`), which is correct against today's pg
  # adapter — it returns real TrueClass/FalseClass, and so does ActiveRecord's
  # own boolean attribute type — and fails OPEN against any other: one adapter,
  # cast or schema change yielding "TRUE" or 1, and the unrecognised value is
  # treated as licence-free, silently unlocking the KYC-gated motorcycle this
  # whole gate exists to hold. A gate on a physical vehicle does not get to be
  # right only for the values someone remembered, and "ActiveRecord already
  # casts it" is the same assumption in a new coat: it is true of the boolean
  # COLUMN this schema has today, which is exactly the premise K-724 says a
  # gate may not rest on.
  #
  # Fail-closed BY CONSTRUCTION, in both directions. Only a value Rails
  # recognises as literally FALSE (false, "f", "false", "0", 0, "") is
  # licence-free; only one it recognises as literally TRUE is licence-required.
  # NULL, an unexpected spelling, or a `needs_licence` that stopped being a
  # boolean column therefore answers `false` to BOTH — so no reading of this
  # column can ever open both doors, and an ambiguous one opens neither.
  def licence_free?     = licence_flag == false
  def licence_required? = licence_flag == true

  private

  def licence_flag = ActiveRecord::Type::Boolean.new.cast(needs_licence)
end
