module Api
  class ConnectionsBaseController < ApplicationController
    before_action :authenticate_user!
    before_action :require_complete_profile!

    rescue_from Connection::Forbidden do |error|
      render json: { errors: [error.message] }, status: :forbidden
    end
    rescue_from Connection::Conflict do |error|
      render json: { errors: [error.message] }, status: :conflict
    end
    rescue_from ActiveRecord::RecordInvalid do |error|
      render json: { errors: error.record.errors.full_messages, fields: error.record.errors.to_hash }, status: 422
    end

    private

    def require_complete_profile!
      unless Profile.complete.exists?(user_id: current_user.id)
        raise Connection::Forbidden, 'Complete your dancer profile first'
      end
    end

    def participant_connection(id)
      Connection.for_user(current_user).find(id)
    end

    def object_params(key, *fields)
      value = params.require(key)
      raise ActionController::BadRequest, "#{key} must be an object" unless value.is_a?(ActionController::Parameters)
      value.permit(*fields)
    end

    def positive_id(value, name)
      raise ActionController::BadRequest, "#{name} must be a positive integer" unless value.to_s.match?(/\A[1-9]\d{0,17}\z/)
      value.to_i
    end

    def paginated(scope, per_page)
      page = positive_id(params.fetch(:page, '1'), 'page')
      raise ActionController::BadRequest, 'page must be at most 999999999' if page > 999999999
      total = scope.count
      {
        data: scope.limit(per_page).offset((page - 1) * per_page).map { |record| yield(record) },
        meta: { page: page, per_page: per_page, total_count: total, total_pages: (total / per_page.to_f).ceil,
                next_page: page * per_page < total ? page + 1 : nil }
      }
    end
  end
end
