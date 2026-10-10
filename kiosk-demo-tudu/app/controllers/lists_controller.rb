# frozen_string_literal: true

# The human pages: a signed-in human's lists, and the public housemate board.
# Reads and writes go through the same projections and Operations the wire uses.
class ListsController < ApplicationController
  include KioskSessionable

  # Bob, the seeded housemate whose lists the public board mirrors (db/seeds.rb).
  HOUSEMATE_ID    = "00000000-0000-0000-0000-000000000002"
  HOUSEMATE_LABEL = "Bob (the housemate)"

  before_action :authenticate_user!, except: %i[index shared]

  rescue_from ActiveRecord::RecordInvalid, Kiosk::Server::Errors::Forbidden do |refusal|
    redirect_to lists_path, alert: refusal.message
  end

  def index
    @lists = kiosk_as_human { List.reachable_rows } if user_signed_in?
    @housemate_board = housemate_board unless user_signed_in?
    @activity = { lists: List.count, todos: Todo.count, done: Todo.where(done: true).count,
                  members: Membership.count }
    advertise_kiosk_skill
  end

  def shared
    @housemate_board = housemate_board
    advertise_kiosk_skill
  end

  def show
    @list_id = params[:id]
    kiosk_as_human do
      ListAccess.member!(@list_id)
      @todos   = Todo.rows_on(@list_id)
      @members = Membership.rows_on(@list_id)
    end
  end

  def create
    title = params.require(:title)
    list  = kiosk_as_human { |identity| CreateListOperation.call(principal_id: identity.user_id, title: title) }
    redirect_to list_path(list[:list_id]), notice: "List created."
  end

  def invite
    invite = kiosk_as_human { |identity| InviteOperation.call(principal_id: identity.user_id, list_id: params[:id]) }
    redirect_to list_path(params[:id]),
                notice: "Invite code (share it, expires in #{invite[:expires_in] / 60} min): #{invite[:code]}"
  end

  private

  def advertise_kiosk_skill
    response.set_header("Link", %(<#{Kiosk.configuration.skill_url}>; rel="kiosk"))
  end

  # Every list Bob is on, newest first, with who shared it and its tasks.
  def housemate_board
    Membership.where(account_id: HOUSEMATE_ID)
      .includes(list: [:todos, { memberships: :account }])
      .sort_by { [-_1.list.created_at.to_f, _1.list_id] }
      .map do |membership|
        list  = membership.list
        owner = list.memberships.find(&:owner?).account
        { "list_id"    => list.id,
          "title"      => list.title,
          "my_role"    => membership.role,
          "owner_name" => User.public_name(owner.display_name, owner.id),
          "tasks"      => list.todos.sort_by { [_1.created_at, _1.id] } }
      end
  end
end
