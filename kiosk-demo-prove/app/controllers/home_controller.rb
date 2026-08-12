# frozen_string_literal: true

# The broker's public root — what this demo is: an anonymizing KYC broker that
# sits between the many government age/licence services and the many operators,
# handing an operator only the minimal anonymized booleans it asked for and
# nothing that identifies the human. This is an ISSUER, not a Kiosk operator: it
# mounts NONE of the four verbs.
class HomeController < ActionController::Base
  def index
    @pending = ProveRequest.where(status: "pending").count
    @confirmed = ProveRequest.where(status: "confirmed").count
  end
end
