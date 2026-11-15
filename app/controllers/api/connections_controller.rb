module Api
  class ConnectionsController < ConnectionsBaseController
    def index
      connections = Connection.for_user(current_user)
      case params[:filter]
      when nil, 'all' then nil
      when 'incoming' then connections = connections.where(recipient_id: current_user.id, status: 'pending')
      when 'outgoing' then connections = connections.where(requester_id: current_user.id, status: 'pending')
      when 'accepted', 'declined', 'ended' then connections = connections.where(status: params[:filter])
      else raise ActionController::BadRequest, 'filter must be all, incoming, outgoing, accepted, declined, or ended'
      end
      render json: paginated(connections.includes(requester: :profile, recipient: :profile).order(:id), 15) { |item| item.public_data(current_user) }
    end

    def show
      render json: { data: participant_connection(params[:id]).public_data(current_user) }
    end

    def relationship
      profile = Profile.complete.find(positive_id(params[:profile_id], 'profile_id'))
      if profile.user_id == current_user.id
        return render json: { errors: ['Choose another dancer'] }, status: 422
      end
      connection = Connection.between(current_user.id, profile.user_id).first
      render json: { data: {
        state: connection ? connection.viewer_state(current_user) : 'none',
        actions: connection ? connection.public_data(current_user)[:actions] : ['connect'],
        connection: connection&.public_data(current_user)
      } }
    end

    def create
      attributes = object_params(:connection, :recipient_profile_id, :intro_message)
      profile = Profile.complete.find(positive_id(attributes[:recipient_profile_id], 'recipient_profile_id'))
      connection = Connection.new(requester: current_user, recipient: profile.user, intro_message: attributes[:intro_message])
      connection.save!
      render json: { data: connection.public_data(current_user) }, status: :created
    rescue ActiveRecord::RecordNotUnique
      render json: { errors: ['A connection already exists for these dancers'], code: 'connection_exists' }, status: :conflict
    end

    def update
      target = object_params(:connection, :status)[:status]
      raise ActionController::BadRequest, 'status must be a string' unless target.is_a?(String)
      connection = participant_connection(params[:id])
      connection.transition!(current_user, target)
      render json: { data: connection.public_data(current_user) }
    end
  end
end
