require 'twilio-ruby'

# alternatively, you can preconfigure the client like so
Twilio.configure do |config|
  config.account_sid  = ENV['TWILIO_ACCOUNT_SID']
  config.auth_token   = ENV['TWILIO_AUTH_TOKEN']
end
