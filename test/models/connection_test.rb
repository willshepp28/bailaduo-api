require 'test_helper'

class ConnectionTest < ActiveSupport::TestCase
  setup do
    @users = 2.times.map do
      user = User.create!(email: "#{SecureRandom.hex(12)}@example.test", password: SecureRandom.hex(16))
      user.create_profile!(display_name: 'Dancer', age: 25, city: 'Playa del Carmen', dance_styles: ['bachata'],
        experience_level: 'beginner', availability: 'Weekends', primary_photo_url: 'https://images.example.test/dancer.jpg')
      user
    end
  end

  test 'database rejects self connections invalid states and missing introduction even without model validation' do
    [
      { requester: @users[0], recipient: @users[0], intro_message: 'Self' },
      { requester: @users[0], recipient: @users[1], intro_message: 'Hello', status: 'invalid' },
      { requester: @users[0], recipient: @users[1], intro_message: ' ' }
    ].each do |attributes|
      error = assert_raises(ActiveRecord::StatementInvalid) do
        Connection.transaction(requires_new: true) { Connection.new(attributes).save!(validate: false) }
      end
      assert_kind_of PG::CheckViolation, error.cause
    end
  end

  test 'acceptance rejects a now incomplete requester and recipient can end accepted connections' do
    connection = Connection.create!(requester: @users[0], recipient: @users[1], intro_message: 'Practice?')
    @users[0].profile.update_columns(city: '')
    assert_raises(Connection::Forbidden) { connection.transition!(@users[1], 'accepted') }
    assert_equal 'pending', connection.reload.status
    @users[0].profile.update!(city: 'Playa del Carmen')
    connection.transition!(@users[1], 'accepted')
    connection.transition!(@users[1], 'ended')
    assert_equal 'ended', connection.reload.status
  end

  test 'message validation and database reject invalid content' do
    connection = Connection.create!(requester: @users[0], recipient: @users[1], intro_message: 'Practice?')
    assert_not connection.messages.new(sender: @users[0], body: 'Before acceptance').valid?
    connection.transition!(@users[1], 'accepted')
    error = assert_raises(ActiveRecord::StatementInvalid) do
      Message.transaction(requires_new: true) do
        connection.messages.new(sender: @users[0], body: '').save!(validate: false)
      end
    end
    assert_kind_of PG::CheckViolation, error.cause
  end
end
