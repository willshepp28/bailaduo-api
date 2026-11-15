Devise.setup do |config|
  require 'devise/orm/active_record'
  config.navigational_formats = []
  config.password_length = 8..72
  config.stretches = Rails.env.test? ? 1 : 12
end
