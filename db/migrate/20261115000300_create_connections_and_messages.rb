class CreateConnectionsAndMessages < ActiveRecord::Migration[7.1]
  def change
    create_table :connections do |t|
      t.references :requester, null: false, foreign_key: { to_table: :users }
      t.references :recipient, null: false, foreign_key: { to_table: :users }
      t.string :status, null: false, default: 'pending'
      t.text :intro_message, null: false
      t.timestamps
    end
    add_index :connections, 'LEAST(requester_id, recipient_id), GREATEST(requester_id, recipient_id)',
              unique: true, name: 'index_connections_on_unordered_pair'
    add_check_constraint :connections, 'requester_id <> recipient_id', name: 'connections_different_users'
    add_check_constraint :connections, "status IN ('pending', 'accepted', 'declined', 'ended')", name: 'connections_valid_status'
    add_check_constraint :connections, 'char_length(btrim(intro_message)) BETWEEN 1 AND 1000', name: 'connections_valid_intro'

    create_table :messages do |t|
      t.references :connection, null: false, foreign_key: true
      t.references :sender, null: false, foreign_key: { to_table: :users }
      t.text :body, null: false
      t.timestamps
    end
    add_index :messages, [:connection_id, :created_at, :id]
    add_check_constraint :messages, 'char_length(btrim(body)) BETWEEN 1 AND 5000', name: 'messages_valid_body'
  end
end
