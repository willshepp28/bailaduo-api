require 'test_helper'

class ApiTest < ActionDispatch::IntegrationTest
  setup do
    @password = SecureRandom.hex(16)
    @user = User.create!(email: 'viewer@example.test', password: @password)
    @headers = @user.create_new_auth_token
  end

  def profile_attributes(overrides = {})
    { display_name: 'Dancer', age: 25, city: 'Playa del Carmen', dance_styles: ['bachata'],
      experience_level: 'beginner', availability: 'Weekends', primary_photo_url: 'https://images.example.test/dancer.jpg' }.merge(overrides)
  end

  def dancer(overrides = {})
    user = User.create!(email: "#{SecureRandom.hex(8)}@example.test", password: @password)
    user.create_profile!(profile_attributes(overrides))
  end

  test 'registration returns safe account data and usable authentication headers' do
    assert_difference('User.count') do
      post '/api/auth', params: { email: 'new@example.test', password: @password, password_confirmation: @password }, as: :json
    end
    assert_response :success
    assert_equal %w[email id], response.parsed_body['data'].keys.sort
    headers = response.headers.slice('access-token', 'client', 'uid')
    assert headers.values.all?(&:present?)
    get '/api/auth/validate_token', headers: headers
    assert_response :ok
    assert_equal 'new@example.test', response.parsed_body.dig('data', 'email')
  end

  test 'invalid registration and duplicate email are rejected' do
    post '/api/auth', params: { email: 'bad', password: 'short' }, as: :json
    assert_response :unprocessable_entity
    assert_no_difference('User.count') do
      post '/api/auth', params: { email: @user.email, password: @password }, as: :json
    end
    assert_response :unprocessable_entity
  end

  test 'login authenticates requests and logout revokes the session' do
    post '/api/auth/sign_in', params: { email: @user.email, password: @password }, as: :json
    assert_response :ok
    assert_equal %w[email id], response.parsed_body['data'].keys.sort
    headers = response.headers.slice('access-token', 'client', 'uid')
    get '/api/profiles', params: { city: 'Playa del Carmen' }, headers: headers
    assert_response :ok
    delete '/api/auth/sign_out', headers: headers
    assert_response :ok
    get '/api/auth/validate_token', headers: headers
    assert_response :unauthorized
  end

  test 'invalid credentials missing credentials and expired tokens are rejected' do
    post '/api/auth/sign_in', params: { email: @user.email, password: SecureRandom.hex(16) }, as: :json
    assert_response :unauthorized
    get '/api/profile'
    assert_response :unauthorized
    post '/api/profile', params: { profile: profile_attributes }, as: :json
    assert_response :unauthorized
    patch '/api/profile', params: { profile: { bio: 'Changed' } }, as: :json
    assert_response :unauthorized
    get '/api/profiles', params: { city: 'Playa del Carmen' }
    assert_response :unauthorized
    travel 15.days do
      get '/api/profile', headers: @headers
      assert_response :unauthorized
    end
  end

  test 'own profile can be created retrieved and updated with ownership enforced' do
    other = dancer
    post '/api/profile', params: { profile: profile_attributes(user_id: other.user_id) }, headers: @headers, as: :json
    assert_response :created
    assert_equal @user.id, Profile.find(response.parsed_body.dig('data', 'id')).user_id
    get '/api/profile', headers: @headers
    assert_response :ok
    patch '/api/profile', params: { profile: { id: other.id, user_id: other.user_id, bio: 'Practice goals' } }, headers: @headers, as: :json
    assert_response :ok
    assert_equal 'Practice goals', @user.reload.profile.bio
    assert_nil other.reload.bio
    patch "/api/profiles/#{other.id}", params: { profile: { bio: 'Hijacked' } }, headers: @headers, as: :json
    assert_response :not_found
    assert_nil other.reload.bio
    post '/api/profile', params: { profile: profile_attributes }, headers: @headers, as: :json
    assert_response :conflict
  end

  test 'missing or incomplete profiles produce useful errors' do
    get '/api/profile', headers: @headers
    assert_response :not_found
    post '/api/profile', params: { profile: { display_name: 'Dancer' } }, headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert response.parsed_body['fields'].key?('age')
    post '/api/profile', params: {}, headers: @headers, as: :json
    assert_response :bad_request
    get '/api/profiles', headers: @headers
    assert_response :bad_request
  end

  test 'invalid updates preserve the existing complete profile and health remains available' do
    @user.create_profile!(profile_attributes)
    patch '/api/profile', params: { profile: { age: 17, primary_photo_url: '' } }, headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert_equal 25, @user.profile.reload.age
    assert_equal 'https://images.example.test/dancer.jpg', @user.profile.primary_photo_url
    get '/up'
    assert_response :ok
  end

  test 'discovery excludes own and incomplete profiles filters city and style and defaults to saved city' do
    @user.create_profile!(profile_attributes)
    included = dancer(dance_styles: ['bachata', 'salsa'])
    dancer(city: 'Cancun')
    dancer(dance_styles: ['salsa'])
    incomplete = dancer
    incomplete.update_columns(display_name: '', dance_styles: [])
    get '/api/profiles', params: { city: ' PLAYA DEL CARMEN ', dance_style: 'BACHATA' }, headers: @headers
    assert_response :ok
    assert_equal [included.id], response.parsed_body['data'].pluck('id')
    get '/api/profiles', headers: @headers
    assert_equal 2, response.parsed_body['meta']['total_count']
    get "/api/profiles/#{incomplete.id}"
    assert_response :not_found
  end

  test 'pagination uses stable ordering and 15 results with metadata' do
    16.times { dancer }
    get '/api/profiles', params: { city: 'Playa del Carmen' }, headers: @headers
    assert_response :ok
    first_ids = response.parsed_body['data'].pluck('id')
    assert_equal 15, first_ids.length
    assert_equal({ 'page' => 1, 'per_page' => 15, 'total_count' => 16, 'total_pages' => 2, 'next_page' => 2 }, response.parsed_body['meta'])
    get '/api/profiles', params: { city: 'Playa del Carmen', page: 2 }, headers: @headers
    assert_equal 1, response.parsed_body['data'].length
    assert_empty first_ids & response.parsed_body['data'].pluck('id')
    assert_nil response.parsed_body['meta']['next_page']
    get '/api/profiles', params: { city: 'Playa del Carmen', page: 3 }, headers: @headers
    assert_empty response.parsed_body['data']
    get '/api/profiles', params: { city: 'Playa del Carmen', page: 'invalid' }, headers: @headers
    assert_response :bad_request
  end

  test 'public profile and discovery expose only public fields' do
    profile = dancer
    get "/api/profiles/#{profile.id}"
    assert_response :ok
    assert_equal Profile::PUBLIC_FIELDS.map(&:to_s).sort, response.parsed_body['data'].keys.sort
    get '/api/profiles', params: { city: profile.city }, headers: @headers
    assert_equal Profile::PUBLIC_FIELDS.map(&:to_s).sort, response.parsed_body['data'].first.keys.sort
    get '/api/profiles/999999999'
    assert_response :not_found
  end

  test 'CORS permits configured origins exposes auth headers and rejects others' do
    options '/api/profile', headers: { 'Origin' => 'https://frontend.example.test', 'Access-Control-Request-Method' => 'PATCH', 'Access-Control-Request-Headers' => 'access-token,client,uid,content-type' }
    assert_response :success
    assert_equal 'https://frontend.example.test', response.headers['access-control-allow-origin']
    exposed = response.headers['access-control-expose-headers'].split(',').map(&:strip)
    assert_equal %w[access-token client expiry token-type uid], exposed.sort
    assert_nil response.headers['access-control-allow-credentials']
    options '/api/profile', headers: { 'Origin' => 'https://untrusted.example.test', 'Access-Control-Request-Method' => 'PATCH' }
    assert_nil response.headers['access-control-allow-origin']
  end

  test 'malformed discovery filters return client errors' do
    [{ city: ['Playa del Carmen'] }, { city: 'Playa del Carmen', dance_style: ['bachata'] }].each do |query|
      get '/api/profiles', params: query, headers: @headers
      assert_response :bad_request
      assert_kind_of Array, response.parsed_body['errors']
    end
  end

  test 'profile envelope must be an object' do
    ['invalid', ['invalid'], 42].each do |payload|
      post '/api/profile', params: { profile: payload }, headers: @headers, as: :json
      assert_response :bad_request
    end
  end

  test 'logout leaves other clients authenticated and forged tokens fail' do
    second_headers = @user.create_new_auth_token
    delete '/api/auth/sign_out', headers: @headers
    assert_response :ok
    get '/api/auth/validate_token', headers: second_headers
    assert_response :ok
    assert_equal %w[email id], response.parsed_body['data'].keys.sort
    get '/api/auth/validate_token', headers: second_headers.merge('access-token' => SecureRandom.hex(16)).except('Authorization')
    assert_response :unauthorized
    delete '/api/auth/sign_out'
    assert_response :not_found
  end
end
