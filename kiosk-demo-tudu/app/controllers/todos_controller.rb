# frozen_string_literal: true

# Add + complete todos from the web UI, through the same registered actions the
# agent wire uses. Membership is enforced by the action (403 → redirect).
#
# Both actions branch on the wire CODE, not on an exception class — since T-057
# the handlers render their refusals, so a refusal arrives as Errors::WireError
# carrying `code`. See ListsController for the same note at length.
class TodosController < ApplicationController
  include KioskSessionable

  before_action :authenticate_user!

  def create
    kiosk_run("add_todo", list_id: params[:list_id], title: params.require(:title))
    redirect_to list_path(params[:list_id]), notice: "Todo added."
  rescue Kiosk::Server::Errors::Base => e
    raise unless %w[bad_request forbidden].include?(e.code)

    redirect_to list_path(params[:list_id]), alert: e.message
  end

  def complete
    kiosk_run("complete_todo", todo_id: params[:id])
    redirect_to list_path(params[:list_id]), notice: "Todo completed."
  rescue Kiosk::Server::Errors::Base => e
    raise unless e.code == "forbidden"

    redirect_to list_path(params[:list_id]), alert: e.message
  end
end
