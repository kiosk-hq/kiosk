# frozen_string_literal: true

# The tutorial-plain tudu web UI for a signed-in human. Every action runs
# through the SAME registered Kiosk queries/actions the agent wire runs (via
# KioskSessionable), so the human and their assistants share one world:
#   index  — the human's lists (owner or member) — my_lists
#   show   — a list's todos + members + the Invite button — list_todos/list_members
#   create — a new list (owner) — create_list
#   invite — mint a collaboration code, shown once — invite
#   shared — the PUBLIC, read-only housemate view — the collaboration reveal
class ListsController < ApplicationController
  include KioskSessionable

  before_action :authenticate_user!, except: %i[index shared]

  # The housemate whose shared world the public board renders: Bob, the seeded
  # MEMBER of the "Flat 3B" household. His stable UUID (db/seeds.rb) lets the
  # read-only board show his lists without a second identity store — when an
  # assistant creates a list and invites/shares it with Bob (or Bob's assistant
  # accepts an invite), the new shared list VISIBLY appears here. This is the
  # (b) reveal: a viewer SEES the collaboration land.
  HOUSEMATE_ID    = "00000000-0000-0000-0000-000000000002"
  HOUSEMATE_LABEL = "Bob (the housemate)"

  # Signed in → the caller's lists (my_lists). Signed out → a plain landing
  # pointing at both doors (sign-in + the Kiosk wire) plus the public housemate
  # board (the collaboration reveal) — the philslist-style api-in-spirit root.
  def index
    @lists = user_signed_in? ? kiosk_query("my_lists") : nil
    @housemate_board = housemate_board unless user_signed_in?

    # App-wide live DOMAIN activity summary (real counts, not telemetry, and
    # NOT principal-scoped — this is the public "what's happening here" tile a
    # visitor lands on). Cheap Model.count reads on tudu's OWN tables.
    @activity = {
      lists:    List.count,
      todos:    Todo.count,
      done:     Todo.where(done: true).count,
      members:  Membership.count,
    }
  end

  # GET /shared — the housemate view on its own URL: a public, read-only mirror
  # of every list Bob (the seeded housemate) is a member of, with each list's
  # tasks and who shared it. No sign-in, no forms, no actions — it only mirrors
  # what the wire (or the web UI) collaborated into being. Refresh to watch a
  # freshly shared list appear.
  def shared
    @housemate_board = housemate_board
    response.set_header("Link", '<https://kiosk.tech/skill.md>; rel="kiosk"')
  end

  # The three actions below branch on the wire CODE rather than on an exception
  # class: since T-057 the handlers are Rails controllers that RENDER their
  # refusals, so what reaches here is Errors::WireError carrying `code`, never
  # Errors::Forbidden/BadRequest. Anything else re-raises, so an unexpected
  # refusal still surfaces instead of being swallowed by a friendly redirect.
  def show
    @list_id = params[:id]
    @todos   = kiosk_query("list_todos",   list_id: @list_id)
    @members = kiosk_query("list_members", list_id: @list_id)
  rescue Kiosk::Server::Errors::Base => e
    raise unless e.code == "forbidden"

    redirect_to lists_path, alert: "That list is not shared with you."
  end

  def create
    value = kiosk_run("create_list", title: params.require(:title))
    redirect_to list_path(value["list_id"]), notice: "List created."
  rescue Kiosk::Server::Errors::Base => e
    raise unless e.code == "bad_request"

    redirect_to lists_path, alert: e.message
  end

  def invite
    value = kiosk_run("invite", list_id: params[:id])
    redirect_to list_path(params[:id]),
                notice: "Invite code (share it, expires in #{value['expires_in'] / 60} min): #{value['code']}"
  rescue Kiosk::Server::Errors::Base => e
    raise unless e.code == "forbidden"

    redirect_to list_path(params[:id]), alert: e.message
  end

  private

  # The public housemate board: every list Bob (the seeded housemate) can reach,
  # each with its tasks and who shared it. Read directly from tudu's OWN tables —
  # this is a viewer's read-only window (like atablefor's reservations board),
  # NOT a membership-gated wire query, so it takes no GUC principal and mutates
  # nothing. One list-header row per membership; each carries its tasks and the
  # owner's handle (the "shared by" attribution). Newest shared list first, so a
  # freshly created+shared list floats to the top when a viewer refreshes.
  def housemate_board
    conn = ActiveRecord::Base.connection
    rows = conn.exec_query(<<~SQL, "housemate_board", [HOUSEMATE_ID]).to_a
      SELECT l.id                                        AS list_id,
             l.title                                     AS title,
             m.role                                      AS my_role,
             owner_u.email                               AS owner_handle,
             l.created_at                                AS created_at
        FROM memberships m
        JOIN lists l           ON l.id = m.list_id
        JOIN memberships om    ON om.list_id = l.id AND om.role = 'owner'
        JOIN users owner_u     ON owner_u.id = om.account_id
       WHERE m.account_id = $1::uuid
       ORDER BY l.created_at DESC, l.id
    SQL

    list_ids = rows.map { |r| r["list_id"] }
    tasks_by_list = tasks_for(conn, list_ids)

    rows.map do |r|
      {
        "list_id"      => r["list_id"],
        "title"        => r["title"],
        "my_role"      => r["my_role"],
        "owner_handle" => r["owner_handle"],
        "tasks"        => tasks_by_list.fetch(r["list_id"], []),
      }
    end
  end

  # Tasks for the board's lists, grouped by list_id (one query, not N+1).
  def tasks_for(conn, list_ids)
    return {} if list_ids.empty?

    placeholders = list_ids.each_index.map { |i| "$#{i + 1}::uuid" }.join(", ")
    conn.exec_query(<<~SQL, "housemate_board tasks", list_ids)
      SELECT list_id, title, done, created_by_agent_id
        FROM todos
       WHERE list_id IN (#{placeholders})
       ORDER BY created_at, id
    SQL
      .to_a.group_by { |t| t["list_id"] }
  end

  helper_method :board_handle_name

  # Public label for an account's email handle: the local-part, masked past the
  # first two chars so a viewer sees "who" without exposing a full address.
  # (tudu has no display_name column; the handle IS the email.)
  def board_handle_name(email)
    email = email.to_s
    return "an assistant account" unless email.include?("@")

    local = email.split("@").first
    local.length <= 2 ? local : "#{local[0, 2]}#{'•' * (local.length - 2)}"
  end
end
