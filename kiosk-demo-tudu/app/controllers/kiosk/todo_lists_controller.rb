# frozen_string_literal: true

# `invite` mints its collaboration code here, so the two libraries that takes
# are required where they are used rather than in an initializer that no longer
# holds any handler.
require "base64"
require "securerandom"

# tudu's WRITE surface: the six verbs an assistant reaches with
# `POST /kiosk/run` — the most of any demo. Same shape as
# Kiosk::HouseholdController — this app's own ApplicationController plus
# `include Kiosk::Action` — because a controller declares queries OR actions,
# never both.
#
# Errors are Rails' idiom end to end: the wire's `error.code` vocabulary is a
# closed table, not a class hierarchy, so a refusal is an ordinary
# `render json:, status:` naming the code, and the wire carries it verbatim. No
# Kiosk error classes appear below — the ten `Errors::BadRequest` /
# `Errors::Forbidden` raises this file replaces are now the two shared renderers
# in {KioskMembershipGate} plus three private ones here. The lambda
# `accept_invite` used to hold — a closure whose only job was to `raise` the same
# 403 from four places inside a transaction — is one of those three, and reads as
# an ordinary guard clause now that a handler is a method with a `return`.
#
# The membership guard every verb but `create_list` and `accept_invite` opens
# with is {KioskMembershipGate}, shared with the query half: tudu is the demo
# where the guard is needed on BOTH sides of the query/action split, so the
# access decision is a model predicate (`Membership.reachable?`) and the refusal
# is a concern. See the note on either one for why the seam runs there.
#
# tudu advertises NO `pay` verb and configures no payment provider, so nothing
# here means a 402: the wire's three payment/PoW codes share that status and
# `Errors::STATUS_CODES` deliberately refuses to guess between them, and the only
# 402 an assistant meets on this origin comes from the registration PoW gate
# upstream of dispatch, never from a handler.
#
# NOT ROUTABLE — see Kiosk::HouseholdController.
class Kiosk::TodoListsController < ApplicationController
  include Kiosk::Action
  include KioskMembershipGate

  # create_list(title) — INSERT a list owned by the AUTHENTICATED principal and,
  # in the SAME transaction, an `owner` membership for the caller. Any forged
  # account_id/owner_id arg is IGNORED: the owner is read from the identity the
  # wire resolved, never from params.
  description "Create a new todo list owned by the authenticated principal. The " \
              "caller becomes its owner (an owner membership is created). Any forged " \
              "account_id/owner_id arg is ignored (owner is the authenticated " \
              "principal). Returns { list_id }."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 title: { type: "string", minLength: 1, description: "The list title." },
               },
               required: ["title"]
  example_params({ title: "Hike" })
  example_row({ list_id: "d4e5f6a7-8b9c-4d0e-9f1a-2b3c4d5e6f70" })
  def create_list
    conn       = ActiveRecord::Base.connection
    account_id = kiosk_identity.user_id
    return render_bad_request("title required") if params[:title].to_s.strip.empty?

    # This `transaction` JOINS the one Kiosk::Server::SessionContext already
    # opened around the whole wire request (the GUCs are SET LOCAL in it), so it
    # opens no second transaction — but the list and its owner membership still
    # land together or not at all, which is the invariant it is written for.
    list_id = conn.transaction do
      id = conn.select_value(<<~SQL)
        INSERT INTO lists (account_id, title, created_at, updated_at)
        VALUES (#{conn.quote(account_id)}::uuid, #{conn.quote(params[:title].to_s)}, now(), now())
        RETURNING id
      SQL
      conn.execute(<<~SQL)
        INSERT INTO memberships (list_id, account_id, role, created_at)
        VALUES (#{conn.quote(id)}::uuid, #{conn.quote(account_id)}::uuid, 'owner', now())
      SQL
      id
    end

    render json: { list_id: list_id }
  end

  # add_todo(list_id, title) — membership-gated; records the acting agent as
  # created_by_agent_id (attribution: "who added the tent? — Bob's assistant").
  # nil for the human web surface, which has no agent.
  description "Add a todo to a list the caller is a member of. The acting agent " \
              "is recorded on the todo (attribution). Forbidden (403) if the caller " \
              "is not a member. Returns { todo_id }."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 list_id: { type: "string", format: "uuid",
                            description: "The list to add to — a `list_id` from my_lists, verbatim." },
                 title:   { type: "string", minLength: 1, description: "The todo text." },
               },
               required: ["list_id", "title"]
  def add_todo
    return unless kiosk_membership_gate(params[:list_id])
    return render_bad_request("title required") if params[:title].to_s.strip.empty?

    conn      = ActiveRecord::Base.connection
    agent_id  = kiosk_identity.agent_id
    agent_sql = agent_id.nil? ? "NULL" : conn.quote(agent_id)
    todo_id = conn.select_value(<<~SQL)
      INSERT INTO todos (list_id, title, done, created_by_agent_id, created_at, updated_at)
      VALUES (#{conn.quote(params[:list_id].to_s)}::uuid, #{conn.quote(params[:title].to_s)},
              false, #{agent_sql}, now(), now())
      RETURNING id
    SQL

    render json: { todo_id: todo_id }
  end

  # complete_todo(todo_id) — membership-gated via the todo's list. UPDATE …
  # WHERE EXISTS(membership); zero rows → 403 (probing can't enumerate ids).
  description "Mark a todo done. Allowed only if the caller is a member of the " \
              "todo's list; otherwise forbidden (403). Returns { todo_id, done }."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 todo_id: { type: "string", format: "uuid",
                            description: "The todo to complete — a `todo_id` from list_todos, verbatim." },
               },
               required: ["todo_id"]
  def complete_todo
    # K-581/K-582: complete_todo takes no list_id, so it never passes through
    # the membership gate — this is the one wire-supplied id in tudu with no
    # other guard in front of its `::uuid` cast. Malformed → 400, not a raw 500.
    unless UuidCheck.valid?(params[:todo_id])
      return render_bad_request(
        "todo_id #{params[:todo_id].to_s.inspect} is not a uuid",
        hint: "Pass a `todo_id` from list_todos, verbatim.",
      )
    end

    conn = ActiveRecord::Base.connection
    rows = conn.execute(<<~SQL)
      UPDATE todos SET done = true, updated_at = now()
      WHERE id = #{conn.quote(params[:todo_id].to_s)}::uuid
        AND EXISTS (
          SELECT 1 FROM memberships
          WHERE memberships.list_id = todos.list_id
            AND memberships.account_id = kiosk.current_user_id()
        )
      RETURNING id
    SQL

    if rows.ntuples.zero?
      return render_forbidden(
        "todo not on a list the authenticated principal is a member of",
        hint: "You may only complete todos on lists you are a member of.",
      )
    end

    render json: { todo_id: params[:todo_id], done: true }
  end

  # invite(list_id) — OWNER-ONLY. Mint a single-use, TTL'd (10 min) collaboration
  # code; store ONLY its SHA-256 digest; return the plaintext { code, expires_in }
  # ONCE. The code travels human-to-human; the recipient's agent redeems it via
  # accept_invite.
  description "Owner-only: mint a single-use, 10-minute collaboration code for a " \
              "list you own. The plaintext code is returned ONCE (only its hash is " \
              "stored) and is meant to be handed to another person, whose assistant " \
              "redeems it with accept_invite. Forbidden (403) if you are not the " \
              "list owner. Returns { code, expires_in }."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 list_id: { type: "string", format: "uuid",
                            description: "The list to share — a `list_id` from my_lists " \
                                         "that you own, verbatim." },
               },
               required: ["list_id"]
  def invite
    return unless kiosk_membership_gate(params[:list_id], require_owner: true)

    conn = ActiveRecord::Base.connection
    # A device_code-grade secret: 256 bits of entropy, base64url. Only the digest
    # is persisted (the kiosk-server LinkCode hygiene, adapted to the domain).
    code   = Base64.urlsafe_encode64(SecureRandom.random_bytes(32), padding: false)
    digest = Invite.digest(code)
    ttl    = 600 # seconds (10 minutes)
    conn.execute(<<~SQL)
      INSERT INTO invites (list_id, code_digest, created_by_account_id, expires_at, created_at)
      VALUES (#{conn.quote(params[:list_id].to_s)}::uuid, #{conn.quote(digest)},
              #{conn.quote(kiosk_identity.user_id)}::uuid, now() + interval '#{ttl} seconds', now())
    SQL

    render json: { code: code, expires_in: ttl }
  end

  # accept_invite(code) — look up by digest; reject foreign/expired/redeemed (403);
  # INSERT a `member` membership for the principal; mark redeemed. A used code
  # fails on the second try (single-use). Returns { list_id, joined: true }.
  description "Redeem a collaboration code someone shared with you: join their " \
              "list as a member. The code is single-use and expires; a used, " \
              "expired, or unknown code is forbidden (403). Returns { list_id, joined }."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 code: { type: "string", minLength: 1,
                         description: "The plaintext invite code you were given." },
               },
               required: ["code"]
  def accept_invite
    code = params[:code].to_s
    # Every refusal below is the SAME sentence on purpose — unknown, expired,
    # already-redeemed and someone-else's are one answer, so a caller holding a
    # bad code learns nothing about which codes exist.
    return render_invite_refused if code.empty?

    conn   = ActiveRecord::Base.connection
    digest = Invite.digest(code)

    # Joins the wire request's SessionContext transaction (see create_list), so
    # each `return` below is an ordinary method return, not a non-local exit
    # from a real transaction block.
    conn.transaction do
      row = conn.execute(<<~SQL).first
        SELECT id, list_id, expires_at, redeemed_at
          FROM invites
         WHERE code_digest = #{conn.quote(digest)}
         FOR UPDATE
      SQL
      return render_invite_refused if row.nil?
      return render_invite_refused unless row["redeemed_at"].nil?

      expired = conn.select_value(
        "SELECT #{conn.quote(row['expires_at'])}::timestamptz < now()",
      )
      return render_invite_refused if expired == true || expired == "t"

      account = kiosk_identity.user_id
      list_id = row["list_id"]
      # Idempotent membership: UNIQUE(list_id, account_id) — if the caller is
      # already a member (e.g. the owner redeeming their own code), do nothing.
      conn.execute(<<~SQL)
        INSERT INTO memberships (list_id, account_id, role, created_at)
        VALUES (#{conn.quote(list_id)}::uuid, #{conn.quote(account)}::uuid, 'member', now())
        ON CONFLICT (list_id, account_id) DO NOTHING
      SQL
      conn.execute(<<~SQL)
        UPDATE invites
           SET redeemed_at = now(), redeemed_by_account_id = #{conn.quote(account)}::uuid
         WHERE id = #{conn.quote(row['id'])}::uuid
      SQL

      render json: { list_id: list_id, joined: true }
    end
  end

  # remove_member(list_id, account_id) — OWNER-ONLY. DELETE the target's
  # membership; access is cut instantly. The owner cannot remove the LAST owner
  # (no orphaning the list). Returns { removed: true }.
  description "Owner-only: remove a member from a list you own — their access is " \
              "cut instantly. You cannot remove the list's last owner. Forbidden " \
              "(403) if you are not the owner. Returns { removed }."
  input_schema type: "object",
               additionalProperties: false,
               properties: {
                 list_id:    { type: "string", format: "uuid",
                               description: "The list to remove a member from — a `list_id` " \
                                            "from my_lists that you own, verbatim." },
                 account_id: { type: "string", format: "uuid",
                               description: "The member account to remove — an `account_id` " \
                                            "from list_members, verbatim." },
               },
               required: ["list_id", "account_id"]
  def remove_member
    return unless kiosk_membership_gate(params[:list_id], require_owner: true)

    target  = params[:account_id].to_s
    list_id = params[:list_id].to_s
    # K-581/K-582: `list_id` was already shape-checked by the membership gate
    # above; `account_id` is a SECOND wire-supplied id, cast `::uuid` in the
    # last-owner probe and the DELETE. Malformed → 400, not a raw 500.
    unless UuidCheck.valid?(target)
      return render_bad_request(
        "account_id #{target.inspect} is not a uuid",
        hint: "Pass an `account_id` from list_members, verbatim.",
      )
    end

    conn = ActiveRecord::Base.connection
    # Guard: never remove the list's LAST owner (would orphan the list). Refuse
    # when the target is an owner AND is the only owner remaining.
    removing_last_owner = conn.select_value(<<~SQL)
      SELECT
        EXISTS (SELECT 1 FROM memberships
                  WHERE list_id = #{conn.quote(list_id)}::uuid
                    AND account_id = #{conn.quote(target)}::uuid
                    AND role = 'owner')
        AND (SELECT count(*) FROM memberships
               WHERE list_id = #{conn.quote(list_id)}::uuid
                 AND role = 'owner') <= 1
    SQL
    if removing_last_owner == true || removing_last_owner == "t"
      return render_forbidden("cannot remove the list's last owner",
                              hint: "A list must keep at least one owner.")
    end

    rows = conn.execute(<<~SQL)
      DELETE FROM memberships
      WHERE list_id = #{conn.quote(list_id)}::uuid
        AND account_id = #{conn.quote(target)}::uuid
      RETURNING id
    SQL

    if rows.ntuples.zero?
      return render_forbidden("no such membership on this list",
                              hint: "The account is not a member of this list.")
    end

    render json: { removed: true }
  end

  private

  # The one refusal this controller adds to the two {KioskMembershipGate}
  # shares. `accept_invite` reaches it from four places and every one of them
  # must say the SAME thing — see the note at the call sites.
  def render_invite_refused
    render_forbidden("invite code is invalid, expired, or already used",
                     hint: "Ask the list owner for a fresh code.")
  end
end
