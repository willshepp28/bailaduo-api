require 'minitest/mock'

module PhotoHelpers
  SETTINGS = {
    'BAILADUO_CLOUDFLARE_ACCOUNT_ID' => 'testaccount',
    'BAILADUO_CLOUDFLARE_IMAGES_HASH' => 'testhash',
    'BAILADUO_CLOUDFLARE_IMAGES_VARIANT' => 'bailaduo-test-profile',
    'BAILADUO_MEDIA_ENVIRONMENT' => 'test',
    'BAILADUO_REQUIRE_MANAGED_PHOTOS' => 'true'
  }.freeze

  def configure_photos
    values = SETTINGS.merge('BAILADUO_CLOUDFLARE_IMAGES_TOKEN' => SecureRandom.hex(16))
    @original_photo_env = values.to_h { |key, value| [key, ENV[key]] }
    values.each { |key, value| ENV[key] = value }
  end

  def restore_photo_configuration
    @original_photo_env&.each { |key, value| value ? ENV[key] = value : ENV.delete(key) }
  end

  def photo_record(user, overrides = {})
    PhotoUpload.create!({ user: user, environment: 'test', provider_account_id: 'testaccount',
      provider_image_id: "bailaduo-test-#{SecureRandom.uuid}", status: 'pending', expires_at: 10.minutes.from_now }.merge(overrides))
  end

  class Provider < CloudflareImages
    attr_accessor :verification_error, :deletion_error, :issuance_error
    attr_reader :deleted, :issued, :verified

    def initialize
      super
      @deleted = []
      @issued = []
      @verified = []
    end

    def issue(upload)
      assert_owned!(upload)
      @issued << upload.id
      raise issuance_error if issuance_error
      "https://upload.imagedelivery.net/testhash/disposable-test-authorization"
    end

    def verify(upload)
      assert_owned!(upload)
      @verified << upload.id
      raise verification_error if verification_error
      { delivery_url: "https://imagedelivery.net/testhash/#{upload.provider_image_id}/bailaduo-test-profile",
        byte_size: 128, content_type: 'image/png' }
    end

    def delete(upload)
      assert_owned!(upload)
      raise deletion_error if deletion_error
      @deleted << upload.id
      true
    end
  end
end
