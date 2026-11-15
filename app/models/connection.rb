class Connection < ApplicationRecord
  class Forbidden < StandardError; end
  class Conflict < StandardError; end

  belongs_to :requester, class_name: 'User'
  belongs_to :recipient, class_name: 'User'
  has_many :messages, dependent: :restrict_with_exception

  before_validation { self.intro_message = intro_message&.strip }
  validates :status, inclusion: { in: %w[pending accepted declined ended] }
  validates :intro_message, presence: true, length: { maximum: 1000 }
  validate :different_users
  validate :completed_profiles, on: :create

  scope :for_user, ->(user) { where(requester_id: user.id).or(where(recipient_id: user.id)) }
  scope :between, ->(first, second) {
    where(requester_id: first, recipient_id: second).or(where(requester_id: second, recipient_id: first))
  }

  def participant?(user)
    [requester_id, recipient_id].include?(user.id)
  end

  def complete_profiles?
    Profile.complete.where(user_id: [requester_id, recipient_id]).count == 2
  end

  def transition!(viewer, target)
    with_lock do
      raise Forbidden, 'Only participants may update this connection' unless participant?(viewer)
      if status == 'pending' && %w[accepted declined].include?(target)
        raise Forbidden, 'Only the recipient may accept or decline' unless recipient_id == viewer.id
        raise Forbidden, 'Both dancers must have complete profiles' if target == 'accepted' && !complete_profiles?
      elsif !(status == 'accepted' && target == 'ended')
        raise Conflict, 'Invalid connection state transition'
      end
      update!(status: target)
    end
  end

  def viewer_state(viewer)
    status == 'pending' ? "#{requester_id == viewer.id ? 'outgoing' : 'incoming'}_pending" : status
  end

  def public_data(viewer)
    state = viewer_state(viewer)
    {
      id: id, status: status, state: state,
      direction: requester_id == viewer.id ? 'outgoing' : 'incoming',
      actions: { 'incoming_pending' => %w[accept decline], 'accepted' => %w[message end] }.fetch(state, []),
      intro_message: intro_message,
      requester_profile: requester.profile&.public_data,
      recipient_profile: recipient.profile&.public_data,
      created_at: created_at, updated_at: updated_at
    }
  end

  private

  def different_users
    errors.add(:recipient, 'must be another dancer') if requester_id.present? && requester_id == recipient_id
  end

  def completed_profiles
    errors.add(:base, 'Both dancers must have complete profiles') unless complete_profiles?
  end
end
