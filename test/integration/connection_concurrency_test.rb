require 'test_helper'
require 'timeout'

# Independent PostgreSQL transactions must see committed users/profiles/tokens.
class ConnectionConcurrencyTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  setup do
    @users = 2.times.map do
      user = User.create!(email: "#{SecureRandom.hex(12)}@example.test", password: SecureRandom.hex(16))
      user.create_profile!(display_name: 'Dancer', age: 25, city: 'Playa del Carmen', dance_styles: ['bachata'],
        experience_level: 'beginner', availability: 'Weekends', primary_photo_url: 'https://images.example.test/dancer.jpg')
      user
    end
    @headers = @users.map(&:create_new_auth_token)
  end

  teardown do
    ids = @users.map(&:id)
    connections = Connection.where(requester_id: ids).or(Connection.where(recipient_id: ids))
    Message.where(connection_id: connections.select(:id)).delete_all
    connections.delete_all
    Profile.where(user_id: ids).delete_all
    User.where(id: ids).delete_all
  end

  def concurrently
    ready = Queue.new
    start = Queue.new
    threads = 2.times.map do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          yield index
        end
      end
    end
    Timeout.timeout(15) { 2.times { ready.pop } }
    2.times { start << true }
    Timeout.timeout(20) { threads.map(&:value) }
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
    threads&.each(&:join)
  end

  test 'simultaneous reciprocal HTTP requests create one durable pair with a controlled conflict' do
    responses = concurrently do |index|
      session = ActionDispatch::Integration::Session.new(Rails.application)
      session.post '/api/connections', params: { connection: { recipient_profile_id: @users[1 - index].profile.id, intro_message: 'Practice together?' } }, headers: @headers[index], as: :json
      [session.response.status, session.response.parsed_body]
    end
    assert_equal [201, 409], responses.map(&:first).sort
    assert_equal 'connection_exists', responses.find { |status, _| status == 409 }.last['code']
    assert_equal 1, Connection.between(*@users.map(&:id)).count
    connection = Connection.between(*@users.map(&:id)).first
    assert_raises(ActiveRecord::RecordNotUnique) do
      Connection.create!(requester_id: connection.recipient_id, recipient_id: connection.requester_id, intro_message: 'Another')
    end
  end

  test 'simultaneous accept and decline serialize to a single terminal decision' do
    connection = Connection.create!(requester: @users[0], recipient: @users[1], intro_message: 'Practice?')
    statuses = concurrently do |index|
      session = ActionDispatch::Integration::Session.new(Rails.application)
      session.patch "/api/connections/#{connection.id}", params: { connection: { status: %w[accepted declined][index] } }, headers: @headers[1], as: :json
      session.response.status
    end
    assert_equal [200, 409], statuses.sort
    assert_includes %w[accepted declined], connection.reload.status
  end

  test 'send and end serialize and ended connection retains history without permitting new messages' do
    connection = Connection.create!(requester: @users[0], recipient: @users[1], intro_message: 'Practice?')
    connection.transition!(@users[1], 'accepted')
    results = concurrently do |index|
      session = ActionDispatch::Integration::Session.new(Rails.application)
      if index.zero?
        session.post "/api/connections/#{connection.id}/messages", params: { message: { body: 'Concurrent message' } }, headers: @headers[0], as: :json
      else
        session.patch "/api/connections/#{connection.id}", params: { connection: { status: 'ended' } }, headers: @headers[1], as: :json
      end
      session.response.status
    end
    assert_includes [201, 403], results[0]
    assert_equal 200, results[1]
    assert_equal 'ended', connection.reload.status
    assert_equal results[0] == 201 ? 1 : 0, connection.messages.count
    count = connection.messages.count
    post "/api/connections/#{connection.id}/messages", params: { message: { body: 'After end' } }, headers: @headers[0], as: :json
    assert_response :forbidden
    get "/api/connections/#{connection.id}/messages", headers: @headers[1]
    assert_response :forbidden
    assert_equal count, connection.messages.count
  end
end
