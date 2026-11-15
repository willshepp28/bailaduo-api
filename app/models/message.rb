class Message < ApplicationRecord
  belongs_to :connection
  belongs_to :sender, class_name: 'User'

  before_validation { self.body = body&.strip }
  validates :body, presence: true, length: { maximum: 5000 }
  validate :accepted_participant, on: :create

  def public_data
    { id: id, connection_id: connection_id, sender_profile_id: sender.profile&.id, body: body, created_at: created_at }
  end

  private

  def accepted_participant
    unless connection && sender && connection.status == 'accepted' && connection.participant?(sender)
      errors.add(:base, 'Only participants in accepted connections may send messages')
    end
  end
end
