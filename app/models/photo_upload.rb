class PhotoUpload < ApplicationRecord
  class Expired < StandardError; end
  class QuotaExceeded < StandardError; end
  class InUse < StandardError; end

  belongs_to :user
  has_one :profile, foreign_key: :primary_photo_upload_id
  validates :provider_image_id, :provider_account_id, :environment, :expires_at, presence: true
  validates :status, inclusion: { in: %w[issuing pending ready attached superseded failed deleted] }

  def self.issue_for!(user, content_type:, byte_size:, provider: CloudflareImages.new)
    unless CloudflareImages::CONTENT_TYPES.include?(content_type) && byte_size.is_a?(Integer) && byte_size.between?(1, CloudflareImages::MAX_BYTES)
      raise CloudflareImages::InvalidImage, 'Choose a JPEG, PNG, or WebP photo of at most 5 MB'
    end
    upload = user.with_lock do
      history = where(user: user)
      if history.where('created_at > ?', 1.hour.ago).count >= 5 || history.where('created_at > ?', 1.day.ago).count >= 20 ||
         history.where(status: %w[issuing pending ready]).where('expires_at > ?', Time.current).count >= 3
        raise QuotaExceeded, 'Photo upload limit reached; cancel unused uploads or try again later'
      end
      create!(user: user, environment: provider.environment, provider_account_id: provider.account_id,
              provider_image_id: "bailaduo-#{provider.environment}-#{SecureRandom.uuid}", expires_at: 10.minutes.from_now)
    end
    # Keep the owned record even if issuance times out: cleanup never needs to
    # discover an unknown provider ID by listing the shared account.
    begin
      url = provider.issue(upload)
      upload.update!(status: 'pending')
      [upload, url]
    rescue CloudflareImages::Error
      upload.update!(status: 'failed')
      raise
    end
  end

  def verify!(provider: CloudflareImages.new)
    with_lock do
      provider.assert_owned!(self)
      return self if status == 'attached'
      if status == 'ready'
        raise Expired, 'Verified photo expired; choose the photo again' if expires_at <= 24.hours.ago
        return self
      end
      raise CloudflareImages::InvalidImage, 'This photo cannot be used' unless status == 'pending'
      raise Expired, 'Photo upload expired; choose the photo again' if expires_at <= Time.current
      update!(provider.verify(self).merge(status: 'ready', verified_at: Time.current))
    end
    self
  end

  def delete_unreferenced!(provider: CloudflareImages.new, abandoned: false)
    with_lock do
      provider.assert_owned!(self)
      raise InUse, 'Photo is currently used by a profile' if referenced?
      return true if status == 'deleted'
      if abandoned && status != 'superseded' && expires_at > 24.hours.ago
        return false
      end
      provider.delete(self)
      update!(status: 'deleted', delivery_url: nil)
    end
    true
  end

  def self.cleanup!(limit: 50)
    provider = CloudflareImages.new
    scope = where(app: 'bailaduo', environment: provider.environment, provider_account_id: provider.account_id)
            .where.not(status: 'deleted').where("status = 'superseded' OR expires_at < ?", 24.hours.ago)
            .where('NOT EXISTS (SELECT 1 FROM profiles WHERE profiles.primary_photo_upload_id = photo_uploads.id OR profiles.primary_photo_url = photo_uploads.delivery_url)')
    result = { deleted: 0, deferred: 0 }
    scope.order(:id).limit(limit.clamp(1, 50)).each do |upload|
      begin
        result[:deleted] += 1 if upload.delete_unreferenced!(provider: provider, abandoned: true)
      rescue CloudflareImages::Error, InUse
        result[:deferred] += 1
      end
    end
    result
  end

  def retire!(provider: CloudflareImages.new)
    with_lock do
      provider.assert_owned!(self)
      return if status == 'deleted'
      return if referenced?
      update!(status: 'superseded')
      begin
        delete_unreferenced!(provider: provider)
      rescue CloudflareImages::Error
        Rails.logger.warn('BailaDuo photo cleanup deferred; retry photos:cleanup')
      end
    end
  end

  def owner_data
    { id: id, status: status, expires_at: expires_at, claim_expires_at: expires_at + 24.hours, primary_photo_url: delivery_url,
      content_type: content_type, byte_size: byte_size }
  end

  private

  def referenced?
    profiles = Profile.where(primary_photo_upload_id: id)
    profiles = profiles.or(Profile.where(primary_photo_url: delivery_url)) if delivery_url.present?
    profiles.exists?
  end
end
