# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc
]

# This shop's OWN personal field. The list above is the Rails generator's and
# covers credentials; a domain argument carrying a human's data — here the
# customer's postal address — is the operator's to add, in the operator's app.
Rails.application.config.filter_parameters << :delivery_address
