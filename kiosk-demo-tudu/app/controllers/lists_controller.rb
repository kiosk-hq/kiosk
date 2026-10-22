# frozen_string_literal: true

# The human pages: a signed-in human's lists, and the public housemate board.
# Reads and writes go through the same projections and Operations the HTTP API uses.
class ListsController < ApplicationController
  include KioskSessionable
  include Kiosk::SkillLink

  # An assistant that ranks Markdown first in Accept (q-value, then order) reads the page as Markdown.
  # Rails alone answers HTML to every Accept that also lists */*.
  before_action only: :index do
    response.set_header('Vary', 'Accept')
    request.format = :md if request.accepts.first == Mime[:md]
  end

  # Bob, the seeded housemate whose lists the public board mirrors (db/seeds.rb).
  HOUSEMATE_ID    = '00000000-0000-0000-0000-000000000002'
  HOUSEMATE_LABEL = 'Bob (the housemate)'

  before_action :authenticate_user!, except: %i[index shared]

  rescue_from ActiveRecord::RecordInvalid, Kiosk::Server::Errors::Forbidden do |refusal|
    redirect_to lists_path, alert: refusal.message
  end

  def index
    @lists = kiosk_as_human { List.reachable.to_a } if user_signed_in?
    @housemate_board = Membership.board_of(HOUSEMATE_ID) unless user_signed_in?
    @activity = { lists: List.count, todos: Todo.count, done: Todo.where(done: true).count,
                  members: Membership.count }
  end

  def shared
    @housemate_board = Membership.board_of(HOUSEMATE_ID)
  end

  def show
    @list_id = params[:id]
    kiosk_as_human do
      ListAccess.member!(@list_id)
      @todos   = Todo.on(@list_id).to_a
      @members = Membership.roster(@list_id).to_a
    end
  end

  def create
    title = params.require(:title)
    list  = kiosk_as_human { |identity| CreateListOperation.call(member_id: identity.user_id, title: title) }
    redirect_to list_path(list), notice: t('.notice')
  end

  def invite
    code = kiosk_as_human { |identity| InviteOperation.call(member_id: identity.user_id, list_id: params[:id]) }
    redirect_to list_path(params[:id]),
                notice: "Invite code (share it, expires in #{InviteOperation::TTL.in_minutes.to_i} min): #{code}"
  end
end
