module Api
  class ProfilesController < ApplicationController
    before_action :authenticate_user!, except: :show

    def index
      %i[city dance_style].each do |field|
        if params.key?(field) && !params[field].is_a?(String)
          raise ActionController::BadRequest, "#{field} must be a string"
        end
      end
      city = params[:city].presence || current_user.profile&.city
      return render json: { errors: ['city is required until you have a profile'] }, status: :bad_request if city.blank?

      page = params.fetch(:page, '1').to_s
      unless page.match?(/\A[1-9]\d{0,8}\z/)
        return render json: { errors: ['page must be a positive integer (maximum 999999999)'] }, status: :bad_request
      end
      page = page.to_i
      profiles = Profile.complete.where.not(user_id: current_user.id).where('lower(city) = ?', city.strip.downcase)
      if params[:dance_style].present?
        profiles = profiles.where('? = ANY(dance_styles)', params[:dance_style].strip.downcase)
      end
      total = profiles.count
      render json: {
        data: profiles.order(:id).limit(15).offset((page - 1) * 15).map(&:public_data),
        meta: { page: page, per_page: 15, total_count: total, total_pages: (total / 15.0).ceil,
                next_page: page * 15 < total ? page + 1 : nil }
      }
    end

    def show
      render json: { data: Profile.complete.find(params[:id]).public_data }
    end

    def mine
      render json: { data: own_profile.public_data }
    end

    def create
      current_user.with_lock do
        if current_user.profile
          return render json: { errors: ['Profile already exists'] }, status: :conflict
        end
        input = profile_params
        profile = current_user.build_profile(input.except(:photo_upload_id))
        persist(profile, :created, input[:photo_upload_id])
      end
    rescue ActiveRecord::RecordNotUnique
      render json: { errors: ['Profile already exists'] }, status: :conflict
    end

    def update
      current_user.with_lock do
        profile = own_profile
        input = profile_params
        profile.assign_attributes(input.except(:photo_upload_id))
        persist(profile, :ok, input[:photo_upload_id])
      end
    end

    private

    def own_profile
      current_user.profile || raise(ActiveRecord::RecordNotFound)
    end

    def profile_params
      attributes = params.require(:profile)
      unless attributes.is_a?(ActionController::Parameters)
        raise ActionController::BadRequest, 'profile must be an object'
      end
      attributes.permit(:display_name, :age, :city, :experience_level, :availability, :bio, :primary_photo_url, :photo_upload_id, dance_styles: [])
    end

    def persist(profile, status, upload_id)
      if upload_id.present?
        unless upload_id.to_s.match?(/\A[1-9]\d{0,17}\z/)
          raise ActionController::BadRequest, 'photo_upload_id must be a positive integer'
        end
        provider = CloudflareImages.new
        upload = current_user.photo_uploads.where(app: 'bailaduo', environment: provider.environment,
                                                  provider_account_id: provider.account_id).find(upload_id)
        upload.with_lock do
          upload.verify!(provider: provider)
          profile.primary_photo_upload = upload
          profile.primary_photo_url = upload.delivery_url
          profile.save!
          upload.update!(status: 'attached')
        end
      else
        validate_photo_rollout!(profile)
        profile.save!
      end
      render json: { data: profile.public_data }, status: status
    end

    def validate_photo_rollout!(profile)
      url_changed = profile.new_record? || profile.will_save_change_to_primary_photo_url?
      return unless url_changed
      host = begin
        URI.parse(profile.primary_photo_url.to_s).host.to_s.downcase
      rescue URI::InvalidURIError
        '' # Normal profile URL validation reports invalid input.
      end
      provider_url = host == 'imagedelivery.net' || host.end_with?('.cloudflareimages.com')
      if profile.primary_photo_upload_id || ENV['BAILADUO_REQUIRE_MANAGED_PHOTOS'] == 'true' || provider_url
        raise CloudflareImages::InvalidImage, 'Select a verified photo_upload_id to create or replace the profile photo'
      end
    end
  end
end
