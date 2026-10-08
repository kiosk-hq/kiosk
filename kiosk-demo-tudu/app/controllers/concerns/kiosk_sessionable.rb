# frozen_string_literal: true

# Runs domain code as the signed-in human, under the same session the wire opens
# for an assistant, so both see one world.
module KioskSessionable
  extend ActiveSupport::Concern

  private

  def kiosk_as_human
    identity = Kiosk::Identity.new(user_id: current_user.id, role: Kiosk.configuration.roles.first.to_s,
                                   actor: "human")
    Kiosk::Server::SessionContext.open(connection: ActiveRecord::Base.connection, identity: identity) do
      yield identity
    end
  end
end
