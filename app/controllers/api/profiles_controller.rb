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
      if current_user.profile
        return render json: { errors: ['Profile already exists'] }, status: :conflict
      end
      profile = current_user.build_profile(profile_params)
      persist(profile, :created)
    rescue ActiveRecord::RecordNotUnique
      render json: { errors: ['Profile already exists'] }, status: :conflict
    end

    def update
      profile = own_profile
      profile.assign_attributes(profile_params)
      persist(profile, :ok)
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
      attributes.permit(:display_name, :age, :city, :experience_level, :availability, :bio, :primary_photo_url, dance_styles: [])
    end

    def persist(profile, status)
      if profile.save
        render json: { data: profile.public_data }, status: status
      else
        render json: { errors: profile.errors.full_messages, fields: profile.errors.to_hash }, status: :unprocessable_entity
      end
    end
  end
end
