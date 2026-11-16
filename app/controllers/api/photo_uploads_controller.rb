module Api
  class PhotoUploadsController < ApplicationController
    before_action :authenticate_user!
    before_action :disable_caching

    def create
      input = params.require(:photo_upload)
      raise ActionController::BadRequest, 'photo_upload must be an object' unless input.is_a?(ActionController::Parameters)
      upload, url = PhotoUpload.issue_for!(current_user, content_type: input[:content_type], byte_size: input[:byte_size])
      render json: { data: upload.owner_data.merge(upload_url: url), limits: {
        max_bytes: CloudflareImages::MAX_BYTES, content_types: CloudflareImages::CONTENT_TYPES
      } }, status: :created
    end

    def show
      render json: { data: owned_upload.owner_data }
    end

    def complete
      upload = owned_upload
      upload.verify!
      render json: { data: upload.owner_data }
    end

    def destroy
      upload = owned_upload
      upload.delete_unreferenced!
      render json: { data: upload.reload.owner_data }
    end

    private

    def owned_upload
      provider = CloudflareImages.new
      PhotoUpload.where(user: current_user, app: 'bailaduo', environment: provider.environment,
                        provider_account_id: provider.account_id).find(params[:id])
    end

    def disable_caching
      response.set_header('Cache-Control', 'no-store')
    end
  end
end
