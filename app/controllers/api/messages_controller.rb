module Api
  class MessagesController < ConnectionsBaseController
    def index
      connection = participant_connection(params[:connection_id])
      data = connection.with_lock do
        require_accepted!(connection)
        paginated(connection.messages.includes(sender: :profile).order(:created_at, :id), 50, &:public_data)
      end
      render json: data
    end

    def create
      attributes = object_params(:message, :body)
      connection = participant_connection(params[:connection_id])
      message = connection.with_lock do
        require_accepted!(connection)
        raise Connection::Forbidden, 'Both dancers must have complete profiles' unless connection.complete_profiles?
        connection.messages.create!(sender: current_user, body: attributes[:body])
      end
      render json: { data: message.public_data }, status: :created
    end

    private

    def require_accepted!(connection)
      raise Connection::Forbidden, 'Messages require an accepted connection' unless connection.status == 'accepted'
    end
  end
end
