require 'test_helper'

class AuthenticationRegressionTest < ActionDispatch::IntegrationTest
  test 'registration rejects ASCII passwords beyond 72 bytes' do
    assert_no_difference('User.count') do
      post '/api/auth', params: { email: 'ascii-limit@example.test', password: SecureRandom.hex(36) + 'a' }, as: :json
      assert_response 422
      assert response.parsed_body['errors'].key?('password')
    end
  end

  test 'registration rejects multibyte passwords beyond 72 bytes even below character limit' do
    password = SecureRandom.hex(16) + '💃' * 11
    assert_operator password.length, :<, 72
    assert_operator password.bytesize, :>, 72
    assert_no_difference('User.count') do
      post '/api/auth', params: { email: 'unicode-limit@example.test', password: password }, as: :json
      assert_response 422
      assert response.parsed_body['errors'].key?('password')
    end
  end

  test 'ASCII and multibyte 72-byte passwords work but longer and different inputs do not' do
    [SecureRandom.hex(36), 'é' * 20 + SecureRandom.hex(16)].each_with_index do |password, index|
      email = "boundary#{index}@example.test"
      assert_equal 72, password.bytesize
      post '/api/auth', params: { email: email, password: password, password_confirmation: password }, as: :json
      assert_response :ok
      post '/api/auth/sign_in', params: { email: email, password: password }, as: :json
      assert_response :ok
      post '/api/auth/sign_in', params: { email: email, password: password + 'x' }, as: :json
      assert_response :unauthorized
      post '/api/auth/sign_in', params: { email: email, password: password[0...-1] + 'z' }, as: :json
      assert_response :unauthorized
    end
  end
end
