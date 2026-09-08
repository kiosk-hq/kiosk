# frozen_string_literal: true

module Kiosk
  module Server
    # THE OPERATOR-SIDE HALF OF A REFUSAL THAT DELIBERATELY DROPS A SENTENCE.
    #
    # Two places in the engine answer the wire with words this protocol chose
    # instead of the words a raised exception happened to carry: {Executor}'s
    # two 500 paths, which keep the exception CLASS and lose the message, and
    # {HandlerMixin::InstanceMethods#kiosk_rescue_to_wire}, which maps a
    # Rails-native raise onto a wire code and publishes a Kiosk sentence for
    # that code. Neither DESTROYS the exception: the class, the message and
    # twenty backtrace frames come here, which is the operator's own log, in
    # the operator's own process, where there is nothing to protect the text
    # from.
    #
    # ONE MODULE RATHER THAN TWO COPIES, because the two sites are the same
    # promise: the `hint` those refusals publish points at the server log, and
    # a second spelling of "what a dropped message looks like in the log" is a
    # second thing to keep in step. The SUMMARY is the caller's — it is what
    # differs between the sites — and everything after the colon is fixed here.
    #
    # Rails' logger when the host app has booted, `Kernel#warn` otherwise (rake
    # tasks, consoles, this gem's own specs). A logger that itself raises must
    # not turn one failure into two, so the whole thing is swallowed.
    module FailureLog
      # How many frames of the dropped exception's backtrace reach the log.
      # Enough to name the operator's own file and the call that reached it,
      # short enough that a per-request refusal does not become a log flood.
      BACKTRACE_FRAMES = 20

      # The prefix every line carries, so an operator can grep one string for
      # "things Kiosk refused and did not put on the wire".
      PREFIX = "[kiosk-server]"

      module_function

      # @param summary [String] what happened, in the CALLER's words — it is
      #   what differs between the two sites, and it is the half that reaches
      #   the wire as well.
      # @param error [Exception] the exception whose message the wire does not
      #   carry.
      # @return [nil]
      def report(summary, error)
        line = "#{PREFIX} #{summary}: #{error.message}\n  " \
               "#{Array(error.backtrace).first(BACKTRACE_FRAMES).join("\n  ")}"
        logger = defined?(::Rails) && ::Rails.respond_to?(:logger) ? ::Rails.logger : nil
        logger ? logger.error(line) : warn(line)
        nil
      rescue StandardError
        nil
      end
    end
  end
end
