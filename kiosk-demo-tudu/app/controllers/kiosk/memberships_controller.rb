# frozen_string_literal: true

# Who is on a list: the members, and the caller's own membership identity.
module Kiosk
  class MembershipsController < ActionController::API
    include Kiosk::Handler

    topic :list_membership do
      reach :consented
      description 'A member `joined` a list you are on, or an owner `removed` one.'
      payload_schema type: 'object', additionalProperties: false,
                     properties: { account_id: { type: 'string', format: 'uuid' },
                                   role: { type: 'string' },
                                   action: { enum: %w[joined removed] } },
                     required: %w[account_id action]
      example account_id: '3c9d2e1f-6a7b-4c8d-9e0f-1a2b3c4d5e6f', role: 'member', action: 'joined'
      example account_id: '3c9d2e1f-6a7b-4c8d-9e0f-1a2b3c4d5e6f', action: 'removed'
      subject_reachable ->(list_id, identity) { Membership.readable_by?(list_id, identity.user_id) }
    end

    kind :query
    description 'Who is signed in for this call: the member, the assistant acting for them, and the ' \
                'name the member shows on shared lists.'
    input_schema type: 'object', additionalProperties: false, properties: {}, required: []
    output_schema type: 'array',
                  description: 'The signed-in member.',
                  minItems: 1, maxItems: 1,
                  items: {
                    type: 'object', additionalProperties: false,
                    properties: {
                      account_id: { type: 'string', description: "The signed-in member's account." },
                      agent_id: { type: %w[string null], description: 'The assistant making this call, or null when a human is signed in.' },
                      display_name: { type: 'string', description: 'The name other members see: the one the member chose, or a generated `member-<hex>` name.' }
                    },
                    required: %w[account_id agent_id display_name]
                  }
    def whoami
      @identity = kiosk_identity
      @account  = User.find(@identity.user_id)
    end

    kind :query
    reach :consented
    description 'Who is on a list you are on, by the name each shows, and their role.'
    input_schema type: 'object',
                 additionalProperties: false,
                 properties: {
                   list_id: { type: 'string', format: 'uuid', description: 'A `list_id` from my_lists.' }
                 },
                 required: ['list_id']
    output_schema type: 'array',
                  description: "The list's members, owners first.",
                  items: {
                    type: 'object', additionalProperties: false,
                    properties: {
                      account_id: { type: 'string', description: 'Pass to remove_member as `account_id`.' },
                      display_name: { type: 'string', description: "The member's chosen name, or a generated `member-<hex>` name." },
                      role: { enum: Membership.roles.keys, description: 'Their role on this list.' }
                    },
                    required: %w[account_id display_name role]
                  }
    def list_members
      ListAccess.member!(params[:list_id])
      @members = Membership.roster(params[:list_id])
    end

    kind :action
    reach :consented
    description 'Owner only: remove a member from a list; their access ends at once. The owner ' \
                'cannot remove themselves.'
    input_schema type: 'object',
                 additionalProperties: false,
                 properties: {
                   list_id: { type: 'string', format: 'uuid', description: 'A `list_id` from my_lists that you own.' },
                   account_id: { type: 'string', format: 'uuid', description: 'An `account_id` from list_members.' }
                 },
                 required: %w[list_id account_id]
    output_schema type: 'object',
                  description: 'The removal.',
                  additionalProperties: false,
                  properties: {
                    removed: { const: true, description: 'Always true.' }
                  },
                  required: ['removed']
    def remove_member
      RemoveMemberOperation.call(list_id: params[:list_id], account_id: params[:account_id])
    end
  end
end
