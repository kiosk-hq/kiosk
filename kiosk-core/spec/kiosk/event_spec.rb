# frozen_string_literal: true

RSpec.describe Kiosk::Event do
  let(:valid) do
    {
      id: "e-1", user_id: "u-1", kind: "booking.confirmed",
      urgency: "normal", payload: { booking_id: "b-9" },
      created_at: Time.now,
    }
  end

  it "constructs with all valid fields" do
    e = described_class.new(**valid)
    expect(e.kind).to    eq("booking.confirmed")
    expect(e.urgency).to eq("normal")
  end

  it "coerces kind to string" do
    e = described_class.new(**valid.merge(kind: :"booking.confirmed"))
    expect(e.kind).to eq("booking.confirmed")
  end

  it "rejects unknown urgency" do
    expect { described_class.new(**valid.merge(urgency: "yelling")) }
      .to raise_error(ArgumentError, /urgency/)
  end

  it "rejects missing kind" do
    expect { described_class.new(**valid.merge(kind: nil)) }
      .to raise_error(ArgumentError, /kind/)
  end

  it "rejects empty kind" do
    expect { described_class.new(**valid.merge(kind: "")) }
      .to raise_error(ArgumentError, /kind/)
  end

  it "defaults payload to empty hash" do
    e = described_class.new(**valid.merge(payload: nil))
    expect(e.payload).to eq({})
  end

  it "permits nil expires_at" do
    e = described_class.new(**valid)
    expect(e.expires_at).to be_nil
  end
end
