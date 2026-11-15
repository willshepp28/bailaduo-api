require 'test_helper'
require 'timeout'

class LogoutConcurrencyTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  test 'two clients authenticated from stale snapshots both remain revoked after concurrent logout' do
    user = User.create!(email: "#{SecureRandom.hex(12)}@example.test", password: SecureRandom.hex(16))
    headers = 3.times.map { user.create_new_auth_token.slice('access-token', 'client', 'uid') }
    loaded = Queue.new
    release = Queue.new
    # Force both requests to authenticate from the same original token JSON.
    # Synchronize before locking/writing so the fixed, serialized path cannot deadlock.
    callback = proc do |record|
      if record.id == user.id && Thread.current[:bailaduo_logout_snapshot]
        Thread.current[:bailaduo_logout_snapshot] = false
        loaded << true
        Timeout.timeout(10) { release.pop }
      end
    end
    User.set_callback(:find, :after, callback)
    threads = headers.first(2).map do |auth|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Thread.current[:bailaduo_logout_snapshot] = true
          session = ActionDispatch::Integration::Session.new(Rails.application)
          session.delete '/api/auth/sign_out', headers: auth
          [session.response.status, session.response.parsed_body]
        ensure
          Thread.current[:bailaduo_logout_snapshot] = nil
        end
      end
    end
    Timeout.timeout(15) { 2.times { loaded.pop } }
    2.times { release << true }
    results = Timeout.timeout(15) { threads.map(&:value) }
    assert_equal [200, 200], results.map(&:first)
    assert results.all? { |_, body| body == { 'success' => true } }
    headers.first(2).each do |auth|
      get '/api/auth/validate_token', headers: auth
      assert_response :unauthorized
    end
    get '/api/auth/validate_token', headers: headers.last
    assert_response :ok
    assert_equal [headers.last['client']], user.reload.tokens.keys
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
    threads&.each(&:join)
    User.skip_callback(:find, :after, callback) if callback
    user&.destroy!
  end
end
