# frozen_string_literal: true

# The single-use invites that add a member to a list.
module Kiosk
  class InvitesController < ActionController::API
    include Kiosk::Handler

    kind :action
    description 'Owner only: create a single-use invite to a list, valid for ten minutes. Give it to the ' \
                'other person; their assistant joins with it through `accept_invite`.'
    input_schema type: 'object',
                 additionalProperties: false,
                 properties: {
                   list_id: { type: 'string', format: 'uuid', description: 'A `list_id` from my_lists that you own.' }
                 },
                 required: ['list_id']
    output_schema type: 'object',
                  description: 'The invite.',
                  additionalProperties: false,
                  properties: {
                    code: { type: 'string', description: 'The invite code. It is shown only this once.' },
                    expires_in: { type: 'integer', description: 'Seconds until it expires.' }
                  },
                  required: %w[code expires_in]
    def invite
      @code = InviteOperation.call(member_id: kiosk_identity.user_id, list_id: params[:list_id])
    end

    kind :action
    reach :consented
    description 'Join a list with an invite somebody gave you. An invite works once, within ten minutes.'
    input_schema type: 'object',
                 additionalProperties: false,
                 properties: {
                   code: { type: 'string', minLength: 1, description: 'The invite code you were given.' }
                 },
                 required: ['code']
    output_schema type: 'object',
                  description: 'The list just joined.',
                  additionalProperties: false,
                  properties: {
                    list_id: { type: 'string', description: 'Pass to list_todos / add_todo as `list_id`.' },
                    joined: { const: true, description: 'Always true.' }
                  },
                  required: %w[list_id joined]
    def accept_invite
      @invite = AcceptInviteOperation.call(member_id: kiosk_identity.user_id, code: params[:code])
    end
  end
end
