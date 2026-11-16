require 'test_helper'
require_relative '../support/photo_helpers'

class PhotoUploadsTest < ActionDispatch::IntegrationTest
  include PhotoHelpers

  setup do
    configure_photos
    @user = User.create!(email: 'photos@example.test', password: SecureRandom.hex(16))
    @headers = @user.create_new_auth_token
    @provider = Provider.new
  end

  teardown { restore_photo_configuration }

  def profile_attributes(overrides = {})
    { display_name: 'Dancer', age: 25, city: 'Playa del Carmen', dance_styles: ['bachata'],
      experience_level: 'beginner', availability: 'Weekends' }.merge(overrides)
  end

  def with_provider(&block)
    CloudflareImages.stub(:new, @provider, &block)
  end

  def issue_photo
    post '/api/photo_uploads', params: { photo_upload: { content_type: 'image/png', byte_size: 128 } }, headers: @headers, as: :json
    assert_response :created
    PhotoUpload.find(response.parsed_body.dig('data', 'id'))
  end

  test 'pre-onboarding user can issue confirm and attach an owned photo without leaking private identifiers' do
    with_provider do
      upload = issue_photo
      assert_equal 'no-store', response.headers['Cache-Control']
      assert_equal 5_000_000, response.parsed_body.dig('limits', 'max_bytes')
      assert response.parsed_body.dig('data', 'upload_url').start_with?('https://upload.imagedelivery.net/')
      assert_not upload.attributes.key?('upload_url')
      assert_nil @user.profile
      post "/api/photo_uploads/#{upload.id}/complete", headers: @headers
      assert_response :ok
      assert_equal 'ready', response.parsed_body.dig('data', 'status')
      post '/api/profile', params: { profile: profile_attributes(photo_upload_id: upload.id, primary_photo_url: 'https://untrusted.example.test/ignore.jpg') }, headers: @headers, as: :json
      assert_response :created
      assert_equal upload.reload.delivery_url, response.parsed_body.dig('data', 'primary_photo_url')
      assert_equal 'attached', upload.status
      assert_equal upload.id, @user.reload.profile.primary_photo_upload_id
      get "/api/profiles/#{@user.profile.id}"
      assert_response :ok
      assert_equal Profile::PUBLIC_FIELDS.map(&:to_s).sort, response.parsed_body['data'].keys.sort
      delete "/api/photo_uploads/#{upload.id}", headers: @headers
      assert_response :conflict
      assert_empty @provider.deleted
    end
  end

  test 'anonymous foreign user and foreign environment account or app references are refused' do
    post '/api/photo_uploads', params: { photo_upload: { content_type: 'image/png', byte_size: 128 } }, as: :json
    assert_response :unauthorized
    other = User.create!(email: 'other-photos@example.test', password: SecureRandom.hex(16))
    [photo_record(other), photo_record(@user, environment: 'production'),
     photo_record(@user, provider_account_id: 'anotheraccount'), photo_record(@user, app: 'jabngo')].each do |upload|
      with_provider do
        get "/api/photo_uploads/#{upload.id}", headers: @headers
        assert_response :not_found
        post "/api/photo_uploads/#{upload.id}/complete", headers: @headers
        assert_response :not_found
        delete "/api/photo_uploads/#{upload.id}", headers: @headers
        assert_response :not_found
        post '/api/profile', params: { profile: profile_attributes(photo_upload_id: upload.id) }, headers: @headers, as: :json
        assert_response :not_found
      end
    end
    assert_empty @provider.verified
    assert_empty @provider.deleted
  end

  test 'incomplete expired failed and invalid provider IDs are never attached' do
    with_provider do
      upload = issue_photo
      @provider.verification_error = CloudflareImages::NotReady.new('Photo upload is not complete yet')
      post "/api/photo_uploads/#{upload.id}/complete", headers: @headers
      assert_response :conflict
      post '/api/profile', params: { profile: profile_attributes(photo_upload_id: upload.id) }, headers: @headers, as: :json
      assert_response :conflict
      assert_nil @user.reload.profile
      @provider.verification_error = nil
      upload.update!(expires_at: 1.second.ago)
      post "/api/photo_uploads/#{upload.id}/complete", headers: @headers
      assert_response :gone
      upload.update!(status: 'failed')
      post "/api/photo_uploads/#{upload.id}/complete", headers: @headers
      assert_response 422
      upload.update!(provider_image_id: 'jabngo-unrelated-asset', status: 'pending', expires_at: 10.minutes.from_now)
      post "/api/photo_uploads/#{upload.id}/complete", headers: @headers
      assert_response 422
      assert_empty @provider.deleted
    end
  end

  test 'limits invalid envelopes missing configuration and provider errors return controlled responses' do
    with_provider do
      [{ content_type: 'image/svg+xml', byte_size: 128 }, { content_type: 'image/png', byte_size: 5_000_001 },
       { content_type: 'image/png', byte_size: '128' }].each do |input|
        post '/api/photo_uploads', params: { photo_upload: input }, headers: @headers, as: :json
        assert_response 422
      end
      post '/api/photo_uploads', params: { photo_upload: 'invalid' }, headers: @headers, as: :json
      assert_response :bad_request
      @provider.issuance_error = CloudflareImages::Error.new('Images provider is unavailable; please retry')
      post '/api/photo_uploads', params: { photo_upload: { content_type: 'image/png', byte_size: 128 } }, headers: @headers, as: :json
      assert_response :bad_gateway
      assert_equal 'failed', PhotoUpload.last.status
    end
    ENV.delete('BAILADUO_CLOUDFLARE_IMAGES_TOKEN')
    post '/api/photo_uploads', params: { photo_upload: { content_type: 'image/png', byte_size: 128 } }, headers: @headers, as: :json
    assert_response :service_unavailable
  end

  test 'issuance quotas are enforced and cancellation never deletes an attached image' do
    with_provider do
      3.times { issue_photo }
      assert_no_difference('PhotoUpload.count') do
        post '/api/photo_uploads', params: { photo_upload: { content_type: 'image/png', byte_size: 128 } }, headers: @headers, as: :json
        assert_response :too_many_requests
      end
      assert_equal 'upload_quota_exceeded', response.parsed_body['code']
      assert_equal '3600', response.headers['Retry-After']
      delete "/api/photo_uploads/#{PhotoUpload.first.id}", headers: @headers
      assert_response :ok
      assert_equal 'deleted', PhotoUpload.first.status
      issue_photo
      PhotoUpload.where(user: @user).update_all(status: 'deleted')
      issue_photo
      assert_equal 5, PhotoUpload.where(user: @user).count
      post '/api/photo_uploads', params: { photo_upload: { content_type: 'image/png', byte_size: 128 } }, headers: @headers, as: :json
      assert_response :too_many_requests
    end
  end

  test 'replacement preserves the previous photo on failed verification or invalid profile then cleans up after success' do
    with_provider do
      old = issue_photo
      post '/api/profile', params: { profile: profile_attributes(photo_upload_id: old.id) }, headers: @headers, as: :json
      assert_response :created
      previous_url = @user.reload.profile.primary_photo_url
      replacement = issue_photo
      @provider.verification_error = CloudflareImages::Error.new('Images provider is unavailable; please retry')
      patch '/api/profile', params: { profile: { photo_upload_id: replacement.id } }, headers: @headers, as: :json
      assert_response :bad_gateway
      assert_equal previous_url, @user.profile.reload.primary_photo_url
      @provider.verification_error = nil
      patch '/api/profile', params: { profile: { photo_upload_id: replacement.id, age: 17 } }, headers: @headers, as: :json
      assert_response 422
      assert_equal previous_url, @user.profile.reload.primary_photo_url
      assert_equal 'pending', replacement.reload.status
      assert_empty @provider.deleted
      patch '/api/profile', params: { profile: { photo_upload_id: replacement.id } }, headers: @headers, as: :json
      assert_response :ok
      assert_equal replacement.id, @user.profile.reload.primary_photo_upload_id
      assert_equal 'deleted', old.reload.status
      assert_equal [old.id], @provider.deleted
    end
  end

  test 'strict rollout gates new photos but preserves existing legacy profiles and edits' do
    post '/api/profile', params: { profile: profile_attributes(primary_photo_url: 'https://images.example.test/new.jpg') }, headers: @headers, as: :json
    assert_response 422
    assert_nil @user.reload.profile
    legacy = @user.create_profile!(profile_attributes(primary_photo_url: 'https://images.example.test/legacy.jpg'))
    patch '/api/profile', params: { profile: { bio: 'Existing dancer' } }, headers: @headers, as: :json
    assert_response :ok
    assert_equal 'https://images.example.test/legacy.jpg', legacy.reload.primary_photo_url
    patch '/api/profile', params: { profile: { primary_photo_url: 'https://images.example.test/replacement.jpg' } }, headers: @headers, as: :json
    assert_response 422
    assert_equal 'https://images.example.test/legacy.jpg', legacy.reload.primary_photo_url
  end

  test 'legacy rollout allows existing frontend creation but never treats an arbitrary provider URL as ownership' do
    ENV['BAILADUO_REQUIRE_MANAGED_PHOTOS'] = 'false'
    post '/api/profile', params: { profile: profile_attributes(primary_photo_url: 'https://imagedelivery.net/other/jabngo/public') }, headers: @headers, as: :json
    assert_response 422
    post '/api/profile', params: { profile: profile_attributes(primary_photo_url: 'https://images.example.test/legacy.jpg') }, headers: @headers, as: :json
    assert_response :created
  end
end
