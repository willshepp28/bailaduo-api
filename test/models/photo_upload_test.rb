require 'test_helper'
require_relative '../support/photo_helpers'

class PhotoUploadTest < ActiveSupport::TestCase
  include PhotoHelpers
  setup do
    configure_photos
    @user = User.create!(email: 'cleanup@example.test', password: SecureRandom.hex(16))
    @provider = Provider.new
  end
  teardown { restore_photo_configuration }

  test 'cleanup is bounded refuses unrelated IDs and preserves active and referenced uploads' do
    old = photo_record(@user, expires_at: 25.hours.ago)
    recent = photo_record(@user)
    foreign = photo_record(@user, app: 'jabngo', expires_at: 25.hours.ago)
    wrong_id = photo_record(@user, provider_image_id: 'jabngo-existing', expires_at: 25.hours.ago)
    CloudflareImages.stub(:new, @provider) do
      result = PhotoUpload.cleanup!(limit: 50)
      assert_equal({ deleted: 1, deferred: 1 }, result)
    end
    assert_equal [old.id], @provider.deleted
    assert_equal 'pending', recent.reload.status
    assert_equal 'pending', foreign.reload.status
    assert_equal 'pending', wrong_id.reload.status
  end

  test 'failed deletion retains superseded record for safe cleanup retry' do
    upload = photo_record(@user)
    upload.verify!(provider: @provider)
    @provider.deletion_error = CloudflareImages::Error.new('Provider unavailable')
    upload.retire!(provider: @provider)
    assert_equal 'superseded', upload.reload.status
    @provider.deletion_error = nil
    CloudflareImages.stub(:new, @provider) { assert_equal 1, PhotoUpload.cleanup![:deleted] }
    assert_equal 'deleted', upload.reload.status
    upload.retire!(provider: @provider)
    assert_equal [upload.id], @provider.deleted
  end

  test 'daily issuance quota includes failed and deleted rows and cannot be evaded by waiting an hour' do
    20.times { photo_record(@user, status: 'failed', created_at: 2.hours.ago) }
    assert_raises(PhotoUpload::QuotaExceeded) do
      PhotoUpload.issue_for!(@user, content_type: 'image/png', byte_size: 128, provider: @provider)
    end
    assert_empty @provider.issued
  end

  test 'verified unattached references expire after their claim window' do
    upload = photo_record(@user)
    upload.verify!(provider: @provider)
    travel 25.hours do
      assert_raises(PhotoUpload::Expired) { upload.verify!(provider: @provider) }
    end
  end

  test 'cleanup also preserves imported URL references without the new foreign key' do
    upload = photo_record(@user)
    upload.verify!(provider: @provider)
    @user.create_profile!(display_name: 'Legacy', age: 28, city: 'Playa del Carmen', dance_styles: ['bachata'],
      experience_level: 'beginner', availability: 'Weekends', primary_photo_url: upload.delivery_url)
    assert_raises(PhotoUpload::InUse) { upload.delete_unreferenced!(provider: @provider) }
    assert_empty @provider.deleted
  end

  test 'referenced rows cannot consume the bounded cleanup batch ahead of abandoned uploads' do
    attached = photo_record(@user)
    attached.verify!(provider: @provider)
    @user.create_profile!(display_name: 'Dancer', age: 28, city: 'Playa del Carmen', dance_styles: ['bachata'],
      experience_level: 'beginner', availability: 'Weekends', primary_photo_upload: attached, primary_photo_url: attached.delivery_url)
    attached.update!(status: 'attached', expires_at: 25.hours.ago)
    abandoned = photo_record(@user, expires_at: 25.hours.ago)
    CloudflareImages.stub(:new, @provider) { assert_equal 1, PhotoUpload.cleanup!(limit: 1)[:deleted] }
    assert_equal [abandoned.id], @provider.deleted
    assert_equal 'attached', attached.reload.status
  end
end
