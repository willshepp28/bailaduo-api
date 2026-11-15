class CreateProfiles < ActiveRecord::Migration[7.1]
  def change
    create_table :profiles do |t|
      t.references :user, null: false, foreign_key: true, index: { unique: true }
      t.string :display_name, null: false
      t.integer :age, null: false
      t.string :city, null: false
      t.string :dance_styles, array: true, null: false, default: []
      t.string :experience_level, null: false
      t.string :availability, null: false
      t.text :bio
      t.string :primary_photo_url, null: false
      t.timestamps
    end
    add_index :profiles, 'lower(city)', name: 'index_profiles_on_lower_city'
    add_check_constraint :profiles, 'age >= 18', name: 'profiles_adult_age'
  end
end
