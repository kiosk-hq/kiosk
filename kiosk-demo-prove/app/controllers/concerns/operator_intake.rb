# frozen_string_literal: true

# Reads an operator's intake request: who sent it, and what it asks for.
module OperatorIntake
  private

  # The registered operator, or nil after it renders the 401.
  def authenticate_operator!
    operator = OperatorRegistry.authenticate(operator_id: operator_id_param, secret: bearer_token)
    render_json({ error: 'unknown operator or bad credential' }, :unauthorized) if operator.nil?
    operator
  end

  # The first rule the intake breaks, as [error, status], or nil.
  def intake_refusal(operator)
    if subject_handle.empty?
      ['missing field: subject_handle', :bad_request]
    elsif !ClaimCatalog.all_known?(requested_claims)
      ["unknown or empty requested_claims; broker can answer: #{ClaimCatalog::ENTRIES.keys.inspect}", :bad_request]
    elsif !OperatorRegistry.callback_allowed?(operator, callback_url)
      # The broker posts only to the operator's registered host.
      ['callback_url host is not allow-listed for this operator', :forbidden]
    elsif !declared_audience_matches?(operator)
      ["audience does not match this operator's registration", :forbidden]
    end
  end

  def declared_audience_matches?(operator)
    declared = intake_body['audience'].to_s
    declared.empty? || declared == audience_for(operator)
  end

  def operator_id_param = intake_body['operator_id'].to_s
  def callback_url = intake_body['callback_url'].to_s
  def subject_handle = intake_body['subject_handle'].to_s
  def requested_claims = Array(intake_body['requested_claims']).map(&:to_s)

  def bearer_token
    auth = request.headers['Authorization'].to_s
    auth.start_with?('Bearer ') ? auth.delete_prefix('Bearer ') : ''
  end

  def intake_body
    @intake_body ||= parse_intake_body
  end

  def parse_intake_body
    body = JSON.parse(request.raw_post.to_s)
    body.is_a?(Hash) ? body : {}
  rescue StandardError
    {}
  end
end
