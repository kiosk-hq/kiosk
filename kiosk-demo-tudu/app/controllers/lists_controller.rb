# frozen_string_literal: true

# The tutorial-plain tudu web UI for a signed-in human. Every action runs the
# SAME domain code the agent wire runs, as the signed-in human (via
# KioskSessionable), so the human and their assistants share one world — and
# since T-082 it runs that code DIRECTLY: reads are model projections, writes are
# the Operations the wire handlers call. Nothing here goes through the wire
# dispatcher, which is for assistants.
#   index  — the human's lists (owner or member) — List.reachable_rows
#   show   — a list's todos + members + the Invite button — ListAccess.check then
#            Todo.rows_on / Membership.rows_on
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
    @lists = user_signed_in? ? kiosk_as_human { List.reachable_rows } : nil
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

    # The SECOND discovery signal on the demo's ROOT (K-944). The
    # `<link rel="kiosk">` tag rides the layout, so it is on every page; the
    # header was set only on #shared, which made tudu the one demo whose HOME
    # page carried a single signal while the fleet claim (K-927) says all seven
    # carry both. protocol.md §4.5 permits either form — this is about the
    # claim being true and the fleet being uniform, not about conformance.
    advertise_kiosk_skill
  end

  # GET /shared — the housemate view on its own URL: a public, read-only mirror
  # of every list Bob (the seeded housemate) is a member of, with each list's
  # tasks and who shared it. No sign-in, no forms, no actions — it only mirrors
  # what the wire (or the web UI) collaborated into being. Refresh to watch a
  # freshly shared list appear.
  def shared
    @housemate_board = housemate_board
    advertise_kiosk_skill
  end

  # The three actions below branch on the wire CODE rather than on an exception
  # class, and anything else re-raises so an unexpected refusal still surfaces
  # instead of being swallowed by a friendly redirect. Since T-082 the code
  # arrives ONE way on both halves — an {OperationResult} carrying a string from
  # the wire's closed vocabulary (T-054: the code table is the contract, not a
  # hierarchy) — because the read half no longer travels through the dispatcher
  # that used to wrap it in an `Errors::WireError` on the way back.
  #
  # ONE gate for the page, where the wire runs its gate once per verb: the two
  # queries this replaces each called {ListAccess.check} themselves, so the page
  # asked the same question twice. Same answer, one question — and it is the SAME
  # {ListAccess.check} the handlers call, so the page cannot come to disagree with
  # the wire about who may read a list. A malformed id still re-raises (it is a
  # `bad_request`, which this page has no way to show), and a foreign one still
  # redirects with the flash.
  def show
    @list_id = params[:id]
    refusal  = kiosk_as_human do
      refused = ListAccess.check(@list_id)
      unless refused
        @todos   = Todo.rows_on(@list_id)
        @members = Membership.rows_on(@list_id)
      end
      refused
    end
    return unless refusal

    kiosk_refusal!(refusal) unless refusal.code == "forbidden"
    redirect_to lists_path, alert: "That list is not shared with you."
  end

  def create
    title  = params.require(:title)
    result = kiosk_as_human { |identity| CreateListOperation.call(principal_id: identity.user_id, title: title) }
    return redirect_to list_path(result.value["list_id"]), notice: "List created." if result.ok?

    kiosk_refusal!(result) unless result.code == "bad_request"
    redirect_to lists_path, alert: result.message
  end

  def invite
    result = kiosk_as_human { |identity| InviteOperation.call(principal_id: identity.user_id, list_id: params[:id]) }
    if result.ok?
      return redirect_to list_path(params[:id]),
                         notice: "Invite code (share it, expires in " \
                                 "#{result.value['expires_in'] / 60} min): #{result.value['code']}"
    end

    kiosk_refusal!(result) unless result.code == "forbidden"
    redirect_to list_path(params[:id]), alert: result.message
  end

  private

  # `Link: <skill-url>; rel="kiosk"` — the response-header half of the discovery
  # pair. The `<link rel="kiosk">` tag half lives in the layout, so every page
  # already carries it; this puts the header on the two pages an assistant is
  # actually pointed at (the root and the public board). Both read
  # `Kiosk.configuration.skill_url`, so the tag, the header and
  # /.well-known/kiosk.json cannot come to name different cuts.
  def advertise_kiosk_skill
    response.set_header("Link", %(<#{Kiosk.configuration.skill_url}>; rel="kiosk"))
  end

  # The public housemate board: every list Bob (the seeded housemate) can reach,
  # each with its tasks and who shared it. Read directly from tudu's OWN tables —
  # this is a viewer's read-only window (like atablefor's reservations board),
  # NOT a membership-gated wire query, so it takes no GUC principal and mutates
  # nothing. One list-header row per membership; each carries its tasks and the
  # owner's DISPLAY NAME (the "shared by" attribution). Newest shared list first,
  # so a freshly created+shared list floats to the top when a viewer refreshes.
  #
  # It used to select `owner_u.email` and mask the local part in the view
  # (`al•••`), which is how the page and the wire came to disagree about how
  # much of an address a reader may see — and masking is itself a disclosure (two
  # characters plus the confirmation that the address holds an account here).
  # Both surfaces now read the SAME value through {User.public_name}, so there is
  # one answer to "what is this person called" and no address on either (K-950).
  def housemate_board
    conn = ActiveRecord::Base.connection
    rows = conn.exec_query(<<~SQL, "housemate_board", [HOUSEMATE_ID]).to_a
      SELECT l.id                                        AS list_id,
             l.title                                     AS title,
             m.role                                      AS my_role,
             owner_u.display_name                        AS owner_display_name,
             om.account_id                               AS owner_account_id,
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
        "owner_name"   => User.public_name(r["owner_display_name"], r["owner_account_id"]),
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

end
