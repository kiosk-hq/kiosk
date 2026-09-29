# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc
]

# This board's OWN personal field. The list above is the Rails generator's and
# matches KEY names carrying credentials; `body` is a listing's free text, and
# `post_listing` asks the assistant to put the seller's phone number or e-mail
# into it. The board PUBLISHES that text — that is the product — but publishing
# it is not a reason to write it into the operator's request log as well.
Rails.application.config.filter_parameters << :body
