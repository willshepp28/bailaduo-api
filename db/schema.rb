# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.1].define(version: 2026_11_16_000100) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "plpgsql"

  create_table "connections", force: :cascade do |t|
    t.bigint "requester_id", null: false
    t.bigint "recipient_id", null: false
    t.string "status", default: "pending", null: false
    t.text "intro_message", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index "LEAST(requester_id, recipient_id), GREATEST(requester_id, recipient_id)", name: "index_connections_on_unordered_pair", unique: true
    t.index ["recipient_id"], name: "index_connections_on_recipient_id"
    t.index ["requester_id"], name: "index_connections_on_requester_id"
    t.check_constraint "char_length(btrim(intro_message)) >= 1 AND char_length(btrim(intro_message)) <= 1000", name: "connections_valid_intro"
    t.check_constraint "requester_id <> recipient_id", name: "connections_different_users"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying::text, 'accepted'::character varying::text, 'declined'::character varying::text, 'ended'::character varying::text])", name: "connections_valid_status"
  end

  create_table "messages", force: :cascade do |t|
    t.bigint "connection_id", null: false
    t.bigint "sender_id", null: false
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["connection_id", "created_at", "id"], name: "index_messages_on_connection_id_and_created_at_and_id"
    t.index ["connection_id"], name: "index_messages_on_connection_id"
    t.index ["sender_id"], name: "index_messages_on_sender_id"
    t.check_constraint "char_length(btrim(body)) >= 1 AND char_length(btrim(body)) <= 5000", name: "messages_valid_body"
  end

  create_table "photo_uploads", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "app", default: "bailaduo", null: false
    t.string "environment", null: false
    t.string "provider_account_id", null: false
    t.string "provider_image_id", null: false
    t.string "status", default: "issuing", null: false
    t.datetime "expires_at", null: false
    t.datetime "verified_at"
    t.string "delivery_url"
    t.string "content_type"
    t.bigint "byte_size"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["provider_account_id", "provider_image_id"], name: "index_photo_uploads_on_provider_identity", unique: true
    t.index ["user_id", "created_at"], name: "index_photo_uploads_on_user_id_and_created_at"
    t.index ["user_id"], name: "index_photo_uploads_on_user_id"
    t.check_constraint "byte_size IS NULL OR byte_size >= 1 AND byte_size <= 5000000", name: "photo_uploads_valid_size"
    t.check_constraint "status::text = ANY (ARRAY['issuing'::character varying, 'pending'::character varying, 'ready'::character varying, 'attached'::character varying, 'superseded'::character varying, 'failed'::character varying, 'deleted'::character varying]::text[])", name: "photo_uploads_valid_status"
  end

  create_table "profiles", force: :cascade do |t|
    t.bigint "user_id", null: false
    t.string "display_name", null: false
    t.integer "age", null: false
    t.string "city", null: false
    t.string "dance_styles", default: [], null: false, array: true
    t.string "experience_level", null: false
    t.string "availability", null: false
    t.text "bio"
    t.string "primary_photo_url", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "primary_photo_upload_id"
    t.index "lower((city)::text)", name: "index_profiles_on_lower_city"
    t.index ["primary_photo_upload_id"], name: "index_profiles_on_primary_photo_upload_id", unique: true
    t.index ["user_id"], name: "index_profiles_on_user_id", unique: true
    t.check_constraint "age >= 18", name: "profiles_adult_age"
  end

  create_table "users", force: :cascade do |t|
    t.string "provider", default: "email", null: false
    t.string "uid", default: "", null: false
    t.string "email", default: "", null: false
    t.string "encrypted_password", default: "", null: false
    t.json "tokens"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["uid", "provider"], name: "index_users_on_uid_and_provider", unique: true
  end

  add_foreign_key "connections", "users", column: "recipient_id"
  add_foreign_key "connections", "users", column: "requester_id"
  add_foreign_key "messages", "connections"
  add_foreign_key "messages", "users", column: "sender_id"
  add_foreign_key "photo_uploads", "users"
  add_foreign_key "profiles", "photo_uploads", column: "primary_photo_upload_id"
  add_foreign_key "profiles", "users"
end
