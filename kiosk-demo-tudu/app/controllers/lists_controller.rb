# frozen_string_literal: true

# The tutorial-plain tudu web UI for a signed-in human. Every action runs
# through the SAME registered Kiosk queries/actions the agent wire runs (via
# KioskSessionable), so the human and their assistants share one world:
#   index  — the human's lists (owner or member) — my_lists
#   show   — a list's todos + members + the Invite button — list_todos/list_members
#   create — a new list (owner) — create_list
#   invite — mint a collaboration code, shown once — invite
class ListsController < ApplicationController
  include KioskSessionable

  before_action :authenticate_user!, except: :index

  # Signed in → the caller's lists (my_lists). Signed out → a plain landing
  # pointing at both doors (sign-in + the Kiosk wire) — the philslist-style
  # api-in-spirit root.
  def index
    @lists = user_signed_in? ? kiosk_query("my_lists") : nil
  end

  def show
    @list_id = params[:id]
    @todos   = kiosk_query("list_todos",   list_id: @list_id)
    @members = kiosk_query("list_members", list_id: @list_id)
  rescue Kiosk::Server::Errors::Forbidden
    redirect_to lists_path, alert: "That list is not shared with you."
  end

  def create
    value = kiosk_run("create_list", title: params.require(:title))
    redirect_to list_path(value[:list_id]), notice: "List created."
  rescue Kiosk::Server::Errors::BadRequest => e
    redirect_to lists_path, alert: e.message
  end

  def invite
    value = kiosk_run("invite", list_id: params[:id])
    redirect_to list_path(params[:id]),
                notice: "Invite code (share it, expires in #{value[:expires_in] / 60} min): #{value[:code]}"
  rescue Kiosk::Server::Errors::Forbidden => e
    redirect_to list_path(params[:id]), alert: e.message
  end
end
