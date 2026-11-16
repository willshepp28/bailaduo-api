class ApplicationController < ActionController::API
  include DeviseTokenAuth::Concerns::SetUserByToken

  rescue_from CloudflareImages::Error do |error|
    render json: { errors: [error.message] }, status: :bad_gateway
  end
  rescue_from PhotoUpload::Expired do |error|
    render json: { errors: [error.message] }, status: :gone
  end
  rescue_from PhotoUpload::QuotaExceeded do |error|
    response.set_header('Retry-After', '3600')
    render json: { errors: [error.message], code: 'upload_quota_exceeded' }, status: :too_many_requests
  end
  rescue_from PhotoUpload::InUse, CloudflareImages::NotReady do |error|
    render json: { errors: [error.message] }, status: :conflict
  end
  rescue_from CloudflareImages::NotConfigured do |error|
    render json: { errors: [error.message] }, status: :service_unavailable
  end
  rescue_from CloudflareImages::InvalidImage do |error|
    render json: { errors: [error.message] }, status: 422
  end
  rescue_from ActiveRecord::RecordInvalid do |error|
    render json: { errors: error.record.errors.full_messages, fields: error.record.errors.to_hash }, status: 422
  end

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
