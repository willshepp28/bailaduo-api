class ApplicationController < ActionController::API
  include DeviseTokenAuth::Concerns::SetUserByToken

  rescue_from ActiveRecord::RecordNotFound do
    render json: { errors: ['Not found'] }, status: :not_found
  end

  rescue_from ActionController::ParameterMissing do |error|
    render json: { errors: [error.message] }, status: :bad_request
  end

  rescue_from ActionController::BadRequest do |error|
    render json: { errors: [error.message] }, status: :bad_request
  end
end
