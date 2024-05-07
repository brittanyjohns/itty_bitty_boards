require "sidekiq/web"

Rails.application.routes.draw do
  resources :team_boards
  resources :team_users
  resources :teams do
    collection do
      post "set_current"
    end
    member do
      post "invite"
      get "accept_invite"
      patch "accept_invite_patch"
      post "add_board"
      delete "remove_board"
    end
  end
  resources :beta_requests
  post "/beta_signup", to: "beta_requests#create", as: :beta_signup

  get "/current_user", to: "current_user#index"

  resources :messages
  resources :openai_prompts
  resources :open_symbols do
    collection do
      get "search"
    end
    member do
      post "save_image"
      post "make_image"
    end
  end
  get "/token" => "application#token"
  get "/service-worker.js" => "service_worker#service_worker"
  get "/manifest.json" => "service_worker#manifest"
  resources :menus do
    member do
      post "rerun"
    end
  end
  resources :docs do
    collection do
      get "deleted"
    end
    member do
      patch "mark_as_current"
      post "move"
      post "find_or_create_image"
      delete "hard_delete"
    end
  end
  # resources :board_images
  resources :images do
    get "menu", on: :collection
    post "find_or_create", on: :collection
    post "set_next_words", on: :collection
    member do
      post "create_audio"
      delete "remove_audio"
      post "generate"
      post "add_to_board"
      post "create_symbol"
    end
  end

  resources :boards do
    collection do
      get "first_predictive_board"
      get "predictive_index"
    end
    member do
      get "build"
      get "fullscreen"
      get "locked"
      get "predictive"
      post "clone"
      post "add_multiple_images"
      post "associate_image"
      post "remove_image"
      post "update_grid"
      get "predictive_images"
    end
  end
  resources :board_images do
    member do
      put "move_up"
      put "move_down"
    end
  end
  # Order matters here.  users needs to be below the devise_for :users
  devise_for :users, controllers: {
                       #  registrations: "users/registrations",
                       sessions: "users/sessions",
                     }
  # devise_for :users, path: '', path_names: {
  #   sign_in: 'login',
  #   sign_out: 'logout',
  #   registration: 'signup'
  # },
  # controllers: {
  #   sessions: 'users/sessions',
  #   registrations: 'users/registrations'
  # }

  resources :users do
    collection do
      get "admin"
    end
    member do
      delete "remove_user_doc"
    end
  end

  get "main/index", as: :home
  get "beta_request", to: "main#beta_request_form", as: :beta_request_form
  get "/privacy", as: :privacy, to: "main#privacy"
  get "dashboard", to: "main#dashboard", as: :dashboard
  get "main/predefined/:id", to: "main#show_predefined", as: :show_predefined
  get "main/demo", as: :demo
  get "/about", as: :about, to: "main#about"
  get "/contact", as: :contact, to: "messages#new"
  get "main/welcome", as: :welcome
  get "main/faq", as: :faq
  get "boards", to: "boards#index", as: :user_root

  get "charges/new"
  get "checkouts/payment", as: :payment
  get "carts/show"
  get "billing/show", to: "billing#show", as: :billing
  get "success", to: "checkouts#success", as: :success
  get "cancel", to: "checkouts#cancel", as: :cancel
  resources :order_items
  resources :products
  resources :checkouts, only: [:new, :create, :show]
  resources :orders, only: [:index, :show]

  #  API routes
  namespace :api, defaults: { format: :json } do
    resources :teams do
      collection do
        post "set_current"
      end
      member do
        post "invite"
        get "accept_invite"
        patch "accept_invite_patch"
        post "add_board"
        delete "remove_board"
        post "create_board"
      end
    end
    resources :images do
      member do
        post "hide_doc"
        post "create_symbol"
        post "set_next_words"
      end
      collection do
        get "search"
        post "find_or_create"
        post "generate"
        post "add_to_board"
        get "predictive"
        get "user_images"
      end
    end

    resources :boards do
      collection do
        get "first_predictive_board"
        get "predictive_index"
        get "user_boards"
      end
      member do
        post "save_layout"
        post "rearrange_images"
        post "add_image"
        post "remove_image"
        get "remaining_images"
        put "associate_image"
        get "predictive_images"
        post "clone"
        put "add_to_team"
        put "remove_from_team"
      end
    end

    resources :board_images do
      member do
        put "move_up"
        put "move_down"
      end
    end

    resources :scenarios

    resources :menus do
      member do
        post "rerun"
      end
    end

    resources :docs do
      collection do
        get "deleted"
      end
      member do
        post "mark_as_current"
        post "move"
        post "find_or_create_image"
        delete "hard_delete"
      end
    end

    resources :users do
      member do
        put "update_settings"
      end
    end

    namespace :v1 do
      resource :auth, only: [:create, :destroy]
      get "users/current", to: "auths#current"
      post "users", to: "auths#sign_up"
      post "users/sign_in", to: "auths#sign_in"
      post "users/sign_out", to: "auths#destroy"
      post "login", to: "auths#create"
      # resources :notification_tokens, only: :create
    end
  end

  namespace :turbo do
    # namespace :ios do
    #   resource :path_configuration, only: :show
    # end
    namespace :android do
      resource :path_configuration, only: :show
    end
  end

  #  CDN routes

  # config/routes.rb
  direct :cdn_image do |model, options|
    puts "model: #{model.inspect}"
    puts "options: #{options}"

    expires_in = options.delete(:expires_in) { ActiveStorage.urls_expire_in }

    if model.respond_to?(:signed_id)
      puts "model.signed_id(expires_in: expires_in): #{model.signed_id(expires_in: expires_in)}"
      route_for(
        :rails_service_blob_proxy,
        model.signed_id(expires_in: expires_in),
        model.filename,
        options.merge(host: ENV["CDN_HOST"])
      )
    else
      puts "No model.signed_id(expires_in: expires_in): #{model.blob.signed_id(expires_in: expires_in)}"
      signed_blob_id = model.blob.signed_id(expires_in: expires_in)
      variation_key = model.variation.key
      filename = model.blob.filename

      route_for(
        :rails_blob_representation_proxy,
        signed_blob_id,
        variation_key,
        filename,
        options.merge(host: ENV["CDN_HOST"])
      )
    end
  end

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  mount Sidekiq::Web => "/sidekiq"

  # Defines the root path route ("/")
  root "main#index"
end
