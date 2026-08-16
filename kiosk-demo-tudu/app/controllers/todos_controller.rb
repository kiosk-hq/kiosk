# frozen_string_literal: true

# Add + complete todos from the web UI, through the same Operations the agent
# wire's handlers call (K-654). Membership is enforced inside the Operation, so
# the human and the assistant meet the identical refusal; here it becomes a
# flash instead of a 403 body.
#
# Both actions branch on the wire CODE, not on an exception class — see
# ListsController for the same note at length. A code neither action knows how
# to show re-raises through {KioskSessionable#kiosk_refusal!}.
class TodosController < ApplicationController
  include KioskSessionable

  before_action :authenticate_user!

  def create
    title  = params.require(:title)
    result = kiosk_as_human do |identity|
      AddTodoOperation.call(agent_id: identity.agent_id, list_id: params[:list_id], title: title)
    end
    return redirect_to list_path(params[:list_id]), notice: "Todo added." if result.ok?

    kiosk_refusal!(result) unless %w[bad_request forbidden].include?(result.code)
    redirect_to list_path(params[:list_id]), alert: result.message
  end

  def complete
    result = kiosk_as_human { CompleteTodoOperation.call(todo_id: params[:id]) }
    return redirect_to list_path(params[:list_id]), notice: "Todo completed." if result.ok?

    kiosk_refusal!(result) unless result.code == "forbidden"
    redirect_to list_path(params[:list_id]), alert: result.message
  end
end
