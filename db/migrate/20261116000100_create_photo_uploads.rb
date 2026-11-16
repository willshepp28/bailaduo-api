class CreatePhotoUploads < ActiveRecord::Migration[7.1]
  def change
    create_table :photo_uploads do |t|
      t.references :user, null: false, foreign_key: true
      t.string :app, null: false, default: 'bailaduo'
      t.string :environment, null: false
      t.string :provider_account_id, null: false
      t.string :provider_image_id, null: false
      t.string :status, null: false, default: 'issuing'
      t.datetime :expires_at, null: false
      t.datetime :verified_at
      t.string :delivery_url
      t.string :content_type
      t.bigint :byte_size
      t.timestamps
    end
    add_index :photo_uploads, [:provider_account_id, :provider_image_id], unique: true, name: 'index_photo_uploads_on_provider_identity'
    add_index :photo_uploads, [:user_id, :created_at]
    add_check_constraint :photo_uploads, "status IN ('issuing', 'pending', 'ready', 'attached', 'superseded', 'failed', 'deleted')", name: 'photo_uploads_valid_status'
    add_check_constraint :photo_uploads, 'byte_size IS NULL OR byte_size BETWEEN 1 AND 5000000', name: 'photo_uploads_valid_size'
    add_reference :profiles, :primary_photo_upload, foreign_key: { to_table: :photo_uploads }, index: { unique: true }
  end
end
