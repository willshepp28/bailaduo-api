class User < ApplicationRecord
  PASSWORD_MAX_BYTES = 72

  devise :database_authenticatable, :registerable, :validatable
  include DeviseTokenAuth::Concerns::User

  has_one :profile, dependent: :destroy
  validate :password_byte_limit

  def valid_password?(candidate)
    return false unless candidate.is_a?(String) && candidate.bytesize <= PASSWORD_MAX_BYTES

    super
  end

  # Explicit allowlist shared by the library's registration/login/token responses.
  def token_validation_response
    { id: id, email: email }
  end

  def as_json(_options = {})
    token_validation_response
  end

  private

  def password_byte_limit
    if password && password.bytesize > PASSWORD_MAX_BYTES
      errors.add(:password, 'must be at most 72 UTF-8 bytes')
    end
  end
end
