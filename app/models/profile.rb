class Profile < ApplicationRecord
  EXPERIENCE_LEVELS = %w[beginner intermediate advanced].freeze
  PUBLIC_FIELDS = %i[id display_name age city dance_styles experience_level availability bio primary_photo_url].freeze

  belongs_to :user
  belongs_to :primary_photo_upload, class_name: 'PhotoUpload', optional: true
  before_validation :normalize_fields
  after_update_commit :retire_previous_photo

  validates :user_id, uniqueness: true
  validates :display_name, :city, :availability, :primary_photo_url, presence: true
  validates :display_name, :city, length: { maximum: 100 }
  validates :availability, length: { maximum: 500 }
  validates :bio, length: { maximum: 2000 }
  validates :primary_photo_url, length: { maximum: 2048 }, format: { with: %r{\Ahttps://[^\s/]+(?:/[^\s]*)?\z}, message: 'must be an HTTPS URL' }
  validates :age, numericality: { only_integer: true, greater_than_or_equal_to: 18, less_than_or_equal_to: 120 }
  validates :experience_level, inclusion: { in: EXPERIENCE_LEVELS }
  validates :dance_styles, presence: true, length: { maximum: 10 }
  validate :valid_dance_styles
  validate :valid_managed_photo

  # Required fields also checked at query time to hide legacy/imported incomplete rows.
  scope :complete, -> {
    where(age: 18..120, experience_level: EXPERIENCE_LEVELS)
      .where("cardinality(dance_styles) BETWEEN 1 AND 10")
      .where("NOT EXISTS (SELECT 1 FROM unnest(dance_styles) AS style WHERE style IS NULL OR btrim(style) = '')")
      .where("btrim(display_name) <> '' AND btrim(city) <> '' AND btrim(availability) <> ''")
      .where("primary_photo_url ~ '^https://[^[:space:]/]+(/[^[:space:]]*)?$'")
  }

  def public_data
    slice(*PUBLIC_FIELDS)
  end

  private

  def valid_managed_photo
    return unless primary_photo_upload
    CloudflareImages.new.assert_owned!(primary_photo_upload)
    unless primary_photo_upload.user_id == user_id && %w[ready attached].include?(primary_photo_upload.status) &&
           primary_photo_upload.verified_at && primary_photo_upload.delivery_url == primary_photo_url
      errors.add(:primary_photo_upload, 'must be a verified photo owned by this dancer')
    end
  end

  def retire_previous_photo
    old_id = saved_change_to_primary_photo_upload_id&.first
    PhotoUpload.find(old_id).retire! if old_id
  rescue CloudflareImages::Error
    Rails.logger.warn('BailaDuo photo cleanup deferred; run photos:cleanup after restoring provider configuration')
  end

  def normalize_fields
    %i[display_name city availability bio primary_photo_url].each do |field|
      self[field] = self[field]&.strip
    end
    self.dance_styles = Array(dance_styles).map { |style| style&.strip&.downcase }.reject(&:blank?).uniq
    self.experience_level = experience_level&.strip&.downcase
  end

  def valid_dance_styles
    errors.add(:dance_styles, 'must contain styles of at most 50 characters') if dance_styles.any? { |style| style.length > 50 }
  end
end
