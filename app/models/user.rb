class User < ApplicationRecord
  devise :database_authenticatable, :registerable, :validatable
  include DeviseTokenAuth::Concerns::User

  has_one :profile, dependent: :destroy

  # Explicit allowlist shared by the library's registration/login/token responses.
  def token_validation_response
    { id: id, email: email }
  end

  def as_json(_options = {})
    token_validation_response
  end
end
