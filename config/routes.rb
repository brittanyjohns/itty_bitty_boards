require "sidekiq/web"

Rails.application.routes.draw do
  resources :scenarios
  post "scenarios/start", to: "scenarios#start"
  post "scenarios/continue", to: "scenarios#continue"
  post "scenarios/finalize", to: "scenarios#finalize"
  get "prompt_templates/index"
  get "prompt_templates/show"
  get "prompt_templates/new"
  get "prompt_templates/edit"
  resources :prompt_templates
  devise_for :child_accounts
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
    end
  end
  resources :board_images do
    member do
      put "save_layout"
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

  #  API routes
  namespace :api, defaults: { format: :json } do
    get "public_boards", to: "boards#public_boards"
    get "public_menu_boards", to: "boards#public_menu_boards"
    post "google_images", to: "google_search_results#image_search"

    get "word_events", to: "audits#word_events", as: :word_events
    post "webhooks", to: "webhooks#webhooks"
    post "checkout", to: "checkouts#create"
    resources :subscriptions do
      collection do
        post "billing_portal"
        post "add_item"
        post "create_customer_session"
        get "list"
      end
      member do
        post "cancel_subscription"
      end
    end
    post "word_click", to: "audits#word_click"
    post "public_word_click", to: "audits#public_word_click"
    resources :beta_requests
    resources :teams do
      collection do
        post "set_current"
      end
      member do
        post "invite"
        delete "remove_member"
        get "accept_invite"
        patch "accept_invite_patch"
        post "add_board"
        delete "remove_board"
        post "create_board"
        get "remaining_boards"
        get "unassigned_accounts"
      end
    end
    resources :messages do
      member do
        post "read", to: "messages#mark_as_read"
        post "unread", to: "messages#mark_as_unread"
      end
    end
    resources :team_accounts
    resources :images do
      member do
        get "public_audio"
        get "prompt_suggestion"
        post "hide_doc"
        post "describe"
        post "create_symbol"
        post "set_next_words"
        post "crop"
        post "clone"
        post "add_doc"
        delete "destroy_audio"
        post "create_audio"
        post "upload_audio"
        post "set_current_audio"
        get "predictive_images"
        post "create_predictive_board"
        post "clear_current"
        post "merge"
      end
      collection do
        post "generate_audio"
        get "find_by_label"
        get "search"
        post "find_or_create"
        post "generate"
        post "add_to_board"
        get "predictive"
        get "predictive_images"
        get "user_images"
        post "crop"
        post "save_temp_doc"
        get "user_docs"
      end
    end
    resources :board_groups do
      collection do
        get "preset"
      end
      member do
        post "rearrange_boards"
        post "save_layout"
        post "remove_board/:board_id", to: "board_groups#remove_board"
      end
    end
    get "sample_voices", to: "images#sample_voices"

    resources :boards do
      resources :images
      collection do
        get "predictive_index"
        get "user_boards"
        get "words"
        get "categories"
        get "preset"
        get "initial_predictive_board"
        post "import_obf"
        post "create_from_template"
        get "common_boards"
      end
      member do
        post "format_with_ai"
        post "save_layout"
        post "rearrange_images"
        post "add_image"
        post "remove_image"
        get "remaining_images"
        put "associate_image"
        put "associate_images"
        post "clone"
        put "add_to_team"
        put "remove_from_team"
        get "predictive_image_board"
        post "create_additional_images"
        get "additional_words"
        get "get_description"
        get "download_obf"
        put "update_preset_display_image"
      end
    end
    resources :board_images do
      collection do
        put "update", to: "board_images#update_multiple"
        delete "remove", to: "board_images#remove_multiple"
      end
    end
    resources :scenarios do
      collection do
        post "suggestion"
        post "get_words"
      end
      member do
        post "answer"
        post "finalize"
      end
    end
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

    resources :child_accounts do
      member do
        post "assign_boards"
        post "send_setup_email"
        delete "remove_board"
      end
    end

    resources :profiles do
      collection do
        get "placeholders"
        get "public/:slug", to: "profiles#public"
        post "generate"
      end
    end
    get "profiles/:slug/check_placeholder", to: "profiles#check_placeholder"

    resources :vendors do
      collection do
        post "generate"
        get "search"
        get "categories"
        get "popular"
        get "featured"
      end
    end

    resources :child_boards do
      collection do
        get "current"
      end
      member do
        put "toggle_favorite"
      end
    end
    namespace :v1 do
      resource :auth, only: [:create, :destroy]
      delete "/child_accounts/logout", to: "child_auths#destroy"
      post "/child_accounts/login", to: "child_auths#create"
      get "/child_accounts/current", to: "child_auths#current"
      get "users/current", to: "auths#current"
      post "users", to: "auths#sign_up"
      post "users/sign_in", to: "auths#sign_in"
      post "users/sign_out", to: "auths#destroy"
      post "login", to: "auths#create"
      post "forgot_password", to: "auths#forgot_password"
      post "reset_password", to: "auths#reset_password"
      post "reset_password_invite", to: "auths#reset_password_invite"
      # resources :notification_tokens, only: :create
    end
    namespace :account do
      resources :boards do
        collection do
          get "initial_predictive_board"
        end
        # member do
        #   get "predictive_image_board"
        # end
      end
      resources :profiles do
        collection do
          get "me"
          put "update_me"
        end
      end
      resources :child_boards do
        collection do
          get "current"
        end
        member do
          get "predictive_board"
        end
      end
      resources :images do
        collection do
          post "find_or_create"
        end
      end
    end
    namespace :admin do
      resources :organizations do
        member do
          post "assign_user"
          post "remove_user"
        end
      end
      resources :events do
        get "download_entries", on: :member
        post "pick_winner", on: :member
      end
      resources :users do
        collection do
          delete "destroy_users"
          get "export"
        end
      end
      resources :teams
      get "word_events", to: "word_events#index", as: :word_events
      resources :boards
    end
    get "events/:slug", to: "events#show"
    post "events/:slug/save_entry", to: "events#save_entry"
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
    expires_in = options.delete(:expires_in) { ActiveStorage.urls_expire_in }

    if model.respond_to?(:signed_id)
      route_for(
        :rails_service_blob_proxy,
        model.signed_id(expires_in: expires_in),
        model.filename,
        options.merge(host: ENV["CDN_HOST"])
      )
    else
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

  # Catch-all route for handling 404 errors. This should be the last route in the file to ensure it catches all unmatched routes.
  match "*path", via: :all, to: "error#not_found"
end
