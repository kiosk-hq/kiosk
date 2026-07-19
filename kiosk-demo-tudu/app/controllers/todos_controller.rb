# frozen_string_literal: true

# Add + complete todos from the web UI, through the same registered actions the
# agent wire uses. Membership is enforced by the action (403 → redirect).
class TodosController < ApplicationController
  include KioskSessionable

  before_action :authenticate_user!

  def create
    kiosk_run("add_todo", list_id: params[:list_id], title: params.require(:title))
    redirect_to list_path(params[:list_id]), notice: "Todo added."
  rescue Kiosk::Server::Errors::BadRequest, Kiosk::Server::Errors::Forbidden => e
    redirect_to list_path(params[:list_id]), alert: e.message
  end

  def complete
    kiosk_run("complete_todo", todo_id: params[:id])
    redirect_to list_path(params[:list_id]), notice: "Todo completed."
  rescue Kiosk::Server::Errors::Forbidden => e
    redirect_to list_path(params[:list_id]), alert: e.message
  end
end
