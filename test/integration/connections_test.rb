require 'test_helper'

class ConnectionsTest < ActionDispatch::IntegrationTest
  setup do
    @alice = make_dancer('alice')
    @bob = make_dancer('bob')
    @outsider = make_dancer('outsider')
    @alice_headers = @alice.create_new_auth_token
    @bob_headers = @bob.create_new_auth_token
    @outsider_headers = @outsider.create_new_auth_token
  end

  def make_dancer(name)
    user = User.create!(email: "#{name}@example.test", password: SecureRandom.hex(16))
    user.create_profile!(display_name: name, age: 25, city: 'Playa del Carmen', dance_styles: ['bachata'],
      experience_level: 'beginner', availability: 'Weekends', primary_photo_url: 'https://images.example.test/dancer.jpg')
    user
  end

  def request_connection
    post '/api/connections', params: { connection: { recipient_profile_id: @bob.profile.id, intro_message: ' Practice this weekend? ', requester_id: @outsider.id } }, headers: @alice_headers, as: :json
    assert_response :created
    @connection = Connection.find(response.parsed_body.dig('data', 'id'))
  end

  def accept_connection
    request_connection
    patch "/api/connections/#{@connection.id}", params: { connection: { status: 'accepted' } }, headers: @bob_headers, as: :json
    assert_response :ok
    @connection.reload
  end

  test 'two-account request accept message journey and relationship states' do
    get '/api/connections/relationship', params: { profile_id: @bob.profile.id }, headers: @alice_headers
    assert_response :ok
    assert_equal({ 'state' => 'none', 'actions' => ['connect'], 'connection' => nil }, response.parsed_body['data'])
    request_connection
    assert_equal @alice.id, @connection.requester_id
    assert_equal 'Practice this weekend?', @connection.intro_message
    assert_equal 'outgoing_pending', response.parsed_body.dig('data', 'state')
    get '/api/connections/relationship', params: { profile_id: @alice.profile.id }, headers: @bob_headers
    assert_equal 'incoming_pending', response.parsed_body.dig('data', 'state')
    assert_equal %w[accept decline], response.parsed_body.dig('data', 'actions')
    assert_equal 'Practice this weekend?', response.parsed_body.dig('data', 'connection', 'intro_message')
    patch "/api/connections/#{@connection.id}", params: { connection: { status: 'accepted', requester_id: @outsider.id } }, headers: @bob_headers, as: :json
    assert_response :ok
    assert_equal 'accepted', response.parsed_body.dig('data', 'state')
    assert_equal %w[message end], response.parsed_body.dig('data', 'actions')
    assert_equal @alice.id, @connection.reload.requester_id
    assert_difference('Message.count', 1) do
      post "/api/connections/#{@connection.id}/messages", params: { message: { body: ' Saturday works! ', sender_id: @outsider.id } }, headers: @alice_headers, as: :json
      assert_response :created
    end
    message_id = response.parsed_body.dig('data', 'id')
    assert_equal @alice.profile.id, response.parsed_body.dig('data', 'sender_profile_id')
    assert_equal @alice.id, Message.find(message_id).sender_id
    post "/api/connections/#{@connection.id}/messages", params: { message: { body: 'See you then' } }, headers: @bob_headers, as: :json
    assert_response :created
    get "/api/connections/#{@connection.id}/messages", headers: @bob_headers
    assert_response :ok
    assert_equal ['Saturday works!', 'See you then'], response.parsed_body['data'].pluck('body')
    assert_equal 2, response.parsed_body.dig('meta', 'total_count')
    assert_equal %w[body connection_id created_at id sender_profile_id], response.parsed_body['data'].first.keys.sort
    get "/api/connections/#{@connection.id}", headers: @alice_headers
    assert_response :ok
    assert_equal Profile::PUBLIC_FIELDS.map(&:to_s).sort, response.parsed_body.dig('data', 'recipient_profile').keys.sort
    assert_not_includes response.body, '@example.test'
  end

  test 'profile edits accepted relationship and message history survive logout and fresh login' do
    password = SecureRandom.hex(16)
    @alice.update!(password: password)
    accept_connection
    patch '/api/profile', params: { profile: { bio: 'Practice on Sundays' } }, headers: @alice_headers, as: :json
    assert_response :ok
    post "/api/connections/#{@connection.id}/messages", params: { message: { body: 'Saved before logout' } }, headers: @alice_headers, as: :json
    assert_response :created
    message_id = response.parsed_body.dig('data', 'id')
    delete '/api/auth/sign_out', headers: @alice_headers
    assert_response :ok
    get "/api/connections/#{@connection.id}/messages", headers: @alice_headers
    assert_response :unauthorized

    post '/api/auth/sign_in', params: { email: @alice.email, password: password }, as: :json
    assert_response :ok
    fresh_headers = response.headers.slice('access-token', 'client', 'uid')
    get '/api/profile', headers: fresh_headers
    assert_response :ok
    assert_equal 'Practice on Sundays', response.parsed_body.dig('data', 'bio')
    get '/api/connections/relationship', params: { profile_id: @bob.profile.id }, headers: fresh_headers
    assert_response :ok
    assert_equal 'accepted', response.parsed_body.dig('data', 'state')
    get "/api/connections/#{@connection.id}/messages", headers: fresh_headers
    assert_response :ok
    assert_equal [message_id], response.parsed_body['data'].pluck('id')
    assert_equal ['Saved before logout'], response.parsed_body['data'].pluck('body')
    get "/api/connections/#{@connection.id}/messages", headers: @bob_headers
    assert_response :ok
    assert_equal [message_id], response.parsed_body['data'].pluck('id')
  end

  test 'only recipient can accept or decline and terminal states cannot reopen' do
    request_connection
    %w[accepted declined].each do |target|
      patch "/api/connections/#{@connection.id}", params: { connection: { status: target } }, headers: @alice_headers, as: :json
      assert_response :forbidden
      assert_equal 'pending', @connection.reload.status
    end
    %w[pending ended bogus].each do |target|
      patch "/api/connections/#{@connection.id}", params: { connection: { status: target } }, headers: @bob_headers, as: :json
      assert_response :conflict
    end
    patch "/api/connections/#{@connection.id}", params: { connection: { status: 'declined' } }, headers: @bob_headers, as: :json
    assert_response :ok
    patch "/api/connections/#{@connection.id}", params: { connection: { status: 'accepted' } }, headers: @bob_headers, as: :json
    assert_response :conflict
    post '/api/connections', params: { connection: { recipient_profile_id: @alice.profile.id, intro_message: 'Try again' } }, headers: @bob_headers, as: :json
    assert_response :conflict
    assert_equal 'connection_exists', response.parsed_body['code']
  end

  test 'outsiders cannot access details transitions or messages or see them in lists' do
    accept_connection
    get "/api/connections/#{@connection.id}", headers: @outsider_headers
    assert_response :not_found
    patch "/api/connections/#{@connection.id}", params: { connection: { status: 'ended' } }, headers: @outsider_headers, as: :json
    assert_response :not_found
    get "/api/connections/#{@connection.id}/messages", headers: @outsider_headers
    assert_response :not_found
    post "/api/connections/#{@connection.id}/messages", params: { message: { body: 'Intrusion' } }, headers: @outsider_headers, as: :json
    assert_response :not_found
    get '/api/connections', headers: @outsider_headers
    assert_empty response.parsed_body['data']
  end

  test 'pending declined and ended connections deny message reads and sends' do
    request_connection
    ['pending', 'declined', 'ended'].each do |state|
      @connection.update_columns(status: state)
      get "/api/connections/#{@connection.id}/messages", headers: @alice_headers
      assert_response :forbidden
      assert_no_difference('Message.count') do
        post "/api/connections/#{@connection.id}/messages", params: { message: { body: 'Not allowed' } }, headers: @bob_headers, as: :json
        assert_response :forbidden
      end
    end
  end

  test 'either accepted participant can end while retaining messages and preventing reconnect' do
    accept_connection
    @connection.messages.create!(sender: @alice, body: 'Retained history')
    patch "/api/connections/#{@connection.id}", params: { connection: { status: 'ended' } }, headers: @alice_headers, as: :json
    assert_response :ok
    assert_equal 'ended', response.parsed_body.dig('data', 'state')
    assert_empty response.parsed_body.dig('data', 'actions')
    assert_equal 1, @connection.messages.count
    patch "/api/connections/#{@connection.id}", params: { connection: { status: 'accepted' } }, headers: @bob_headers, as: :json
    assert_response :conflict
    post '/api/connections', params: { connection: { recipient_profile_id: @bob.profile.id, intro_message: 'Reconnect' } }, headers: @alice_headers, as: :json
    assert_response :conflict
  end

  test 'self requests missing introduction and duplicate directions are rejected' do
    post '/api/connections', params: { connection: { recipient_profile_id: @alice.profile.id, intro_message: 'Self' } }, headers: @alice_headers, as: :json
    assert_response 422
    ['', ' ', 'x' * 1001, nil].each do |intro|
      post '/api/connections', params: { connection: { recipient_profile_id: @bob.profile.id, intro_message: intro } }, headers: @alice_headers, as: :json
      assert_response 422
    end
    request_connection
    [@alice, @bob].each do |viewer|
      target = viewer == @alice ? @bob : @alice
      headers = viewer == @alice ? @alice_headers : @bob_headers
      assert_no_difference('Connection.count') do
        post '/api/connections', params: { connection: { recipient_profile_id: target.profile.id, intro_message: 'Duplicate' } }, headers: headers, as: :json
        assert_response :conflict
        assert_equal 'connection_exists', response.parsed_body['code']
      end
    end
  end

  test 'completed profiles are required on server and accepted participants must remain complete to send' do
    incomplete = User.create!(email: 'incomplete@example.test', password: SecureRandom.hex(16))
    headers = incomplete.create_new_auth_token
    post '/api/connections', params: { connection: { recipient_profile_id: @bob.profile.id, intro_message: 'Hi' } }, headers: headers, as: :json
    assert_response :forbidden
    accept_connection
    @alice.profile.update_columns(availability: '')
    post "/api/connections/#{@connection.id}/messages", params: { message: { body: 'Hi' } }, headers: @bob_headers, as: :json
    assert_response :forbidden
    get '/api/connections', headers: @alice_headers
    assert_response :forbidden
  end

  test 'incomplete recipients cannot receive requests' do
    @bob.profile.update_columns(primary_photo_url: '')
    assert_no_difference('Connection.count') do
      post '/api/connections', params: { connection: { recipient_profile_id: @bob.profile.id, intro_message: 'Practice?' } }, headers: @alice_headers, as: :json
      assert_response :not_found
    end
  end

  test 'connection filters and both paginations return only permitted rows' do
    request_connection
    get '/api/connections', params: { filter: 'outgoing' }, headers: @alice_headers
    assert_equal [@connection.id], response.parsed_body['data'].pluck('id')
    get '/api/connections', params: { filter: 'incoming' }, headers: @bob_headers
    assert_equal [@connection.id], response.parsed_body['data'].pluck('id')
    get '/api/connections', params: { filter: 'accepted' }, headers: @bob_headers
    assert_empty response.parsed_body['data']
    @connection.transition!(@bob, 'accepted')
    get '/api/connections', params: { filter: 'accepted' }, headers: @bob_headers
    assert_equal [@connection.id], response.parsed_body['data'].pluck('id')
    15.times do |index|
      target = make_dancer("extra#{index}")
      Connection.create!(requester: @alice, recipient: target, intro_message: 'Practice?')
    end
    get '/api/connections', headers: @alice_headers
    assert_equal 15, response.parsed_body['data'].size
    assert_equal 2, response.parsed_body.dig('meta', 'next_page')
    get '/api/connections', params: { page: 2 }, headers: @alice_headers
    assert_equal 1, response.parsed_body['data'].size
    assert_nil response.parsed_body.dig('meta', 'next_page')
    time = Time.current
    51.times { |index| @connection.messages.create!(sender: @bob, body: "Message #{index}", created_at: time) }
    get "/api/connections/#{@connection.id}/messages", headers: @alice_headers
    first_ids = response.parsed_body['data'].pluck('id')
    assert_equal first_ids.sort, first_ids
    assert_equal 50, first_ids.size
    assert_equal 2, response.parsed_body.dig('meta', 'next_page')
    get "/api/connections/#{@connection.id}/messages", params: { page: 2 }, headers: @bob_headers
    assert_equal ['Message 50'], response.parsed_body['data'].pluck('body')
  end

  test 'invalid inputs and anonymous access have controlled errors' do
    get '/api/connections'
    assert_response :unauthorized
    post '/api/connections', params: { connection: 'invalid' }, headers: @alice_headers, as: :json
    assert_response :bad_request
    get '/api/connections/relationship', params: { profile_id: ['invalid'] }, headers: @alice_headers
    assert_response :bad_request
    get '/api/connections', params: { filter: 'invalid' }, headers: @alice_headers
    assert_response :bad_request
    get '/api/connections', params: { page: 0 }, headers: @alice_headers
    assert_response :bad_request
    get '/api/connections', params: { page: 999999999999999999 }, headers: @alice_headers
    assert_response :bad_request
    accept_connection
    ['', 'x' * 5001].each do |body|
      post "/api/connections/#{@connection.id}/messages", params: { message: { body: body } }, headers: @bob_headers, as: :json
      assert_response 422
    end
  end
end
