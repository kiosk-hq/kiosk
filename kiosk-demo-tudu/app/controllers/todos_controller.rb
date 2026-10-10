# frozen_string_literal: true

# Adds and completes todos from the web page, through the Operations the wire calls.
class TodosController < ApplicationController
  include KioskSessionable

  before_action :authenticate_user!

  rescue_from ActiveRecord::RecordInvalid, Kiosk::Server::Errors::Forbidden do |refusal|
    redirect_to list_path(params[:list_id]), alert: refusal.message
  end

  def create
    title = params.require(:title)
    kiosk_as_human do |identity|
      AddTodoOperation.call(agent_id: identity.agent_id, list_id: params[:list_id], title: title)
    end
    redirect_to list_path(params[:list_id]), notice: "Todo added."
  end

  def complete
    kiosk_as_human { CompleteTodoOperation.call(todo_id: params[:id]) }
    redirect_to list_path(params[:list_id]), notice: "Todo completed."
  end
end
