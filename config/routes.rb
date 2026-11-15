Rails.application.routes.draw do
  get 'up' => 'rails/health#show', as: :rails_health_check

  devise_for :users, skip: :all
  devise_scope :user do
    scope '/api/auth', defaults: { format: :json } do
      post '/', to: 'devise_token_auth/registrations#create'
      post '/sign_in', to: 'devise_token_auth/sessions#create'
      delete '/sign_out', to: 'devise_token_auth/sessions#destroy'
      get '/validate_token', to: 'devise_token_auth/token_validations#validate_token'
    end
  end

  namespace :api do
    get 'profile', to: 'profiles#mine'
    post 'profile', to: 'profiles#create'
    patch 'profile', to: 'profiles#update'
    resources :profiles, only: [:index, :show]
    patch 'connections/:id', to: 'connections#update'
    resources :connections, only: [:index, :show, :create] do
      get :relationship, on: :collection
      resources :messages, only: [:index, :create]
    end
  end
end
