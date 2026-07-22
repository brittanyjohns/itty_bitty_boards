require "sidekiq/web"

Rails.application.routes.draw do
  devise_for :child_accounts
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

  get "/current_user", to: "current_user#index"

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
  # Order matters here.  users needs to be below the devise_for :users
  devise_for :users, controllers: {
                       #  registrations: "users/registrations",
                       sessions: "users/sessions",
                       confirmations: "users/confirmations",
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

  # HTML admin area (Mission Control dashboard)
  namespace :admin do
    root "dashboard#index"
    resource :mission_control, only: [:show], controller: 'mission_control' do
      post :cleanup_demo
    end
    resources :users, only: [:index, :show, :update, :destroy], as: :dashboard_users do
      member do
        post :adjust_credits
        post :change_plan
        post :send_welcome_email
        post :send_setup_email
        post :send_temp_login_email
      end
    end
    resources :clinician_applications, only: [:index], as: :dashboard_clinician_applications do
      member do
        post :approve
        post :deny
      end
    end
    resources :video_boards, only: [:index, :new, :create, :show, :destroy], as: :dashboard_video_boards do
      member do
        post :publish
        post :unpublish
      end
    end
  end

  get "main/index", as: :home
  get "beta_request", to: "main#beta_request_form", as: :beta_request_form
  get "/privacy", as: :privacy, to: "main#privacy"
  get "dashboard", to: "main#dashboard", as: :dashboard
  get "main/predefined/:id", to: "main#show_predefined", as: :show_predefined
  get "main/demo", as: :demo
  get "/about", as: :about, to: "main#about"
  # get "/contact", as: :contact, to: "messages#new"
  get "main/welcome", as: :welcome
  get "main/faq", as: :faq

  #  API routes
  namespace :api, defaults: { format: :json } do
    get "stats", to: "stats#index"
    namespace :stripe do
      resources :checkout_sessions, only: :create do
        collection do
          post "topup"
          post "license"
        end
      end
      post "update_user_from_session", to: "checkout_sessions#update_user_from_session"
    end
    namespace :profiles do
      post ":id/safety_id", to: "assets#safety_id"
      post ":id/device_tag", to: "assets#device_tag"
    end
    post "billing/update_subscription", to: "billing#update_subscription"
    post "billing/webhooks", to: "billing#webhooks"
    # SpeakAnyWay for Clinicians — applicant-facing endpoints.
    resources :clinician_applications, only: [:create] do
      collection do
        get "mine"
      end
    end
    post "open_symbols/search", to: "open_symbols#search_api"
    get "temp-login/:token", to: "temp_logins#show"
    post "set-password", to: "users#set_password"
    patch "update_email", to: "users#update_email"
    post "resend_email_confirmation", to: "users#resend_email_confirmation"
    post "cancel_email_change", to: "users#cancel_email_change"
    get "confirm_email_change", to: "users#confirm_email_change"
    resources :feedback, only: [:create]

    get "audio/play", to: "audio#play"

    get "preset_colors", to: "application#preset_colors"
    get "voices", to: "application#voice_options"

    get "public_boards", to: "boards#public_boards"
    get "public_menu_boards", to: "boards#public_menu_boards"

    # Anonymous free-board-download lead capture (both public / no-auth).
    get "free_download_boards", to: "boards#free_download_boards"
    post "download_leads", to: "download_leads#create"
    post "google_images", to: "google_search_results#image_search"
    post "youtube_search", to: "youtube_search#search"

    resources :board_screenshot_imports
    post "board_screenshot_imports/:id/commit", to: "board_screenshot_imports#commit"

    get "word_events/stats", to: "audits#communicator_stats", as: :word_events_stats
    get "word_events", to: "audits#word_events", as: :word_events
    post "webhooks", to: "webhooks#webhooks"
    resources :subscriptions do
      collection do
        post "billing_portal"
        post "change_plan_portal_session"
        post "preview_plan_change"
        post "change_plan"
        post "add_item"
        post "communicator_addon"
        post "create_customer_session"
        get "list"
      end
      member do
        post "cancel_subscription"
      end
    end

    resources :page_follows, only: [:create]
    delete "page_follows/:followed_page_id", to: "page_follows#destroy"

    get "pages/:id/follow_summary", to: "pages#follow_summary"
    get "pages/discover", to: "pages#discover"

    get "me/followed_pages", to: "me#followed_pages"
    get "me/page_followers", to: "me#page_followers"
    get "me/credits", to: "me#credits"
    get "me/credit_transactions", to: "me#credit_transactions"
    get "credits/feature_costs", to: "credits#feature_costs"

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
        delete "leave"
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
        get "all_board_images"
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
        get "graph"
        post "rearrange_boards"
        post "save_layout"
        post "add_board/:board_id", to: "board_groups#add_board"
        post "remove_board/:board_id", to: "board_groups#remove_board"
      end
    end
    # Back-compat alias: the board-set map handoff documented the graph endpoint
    # under /api/v1/, but board_groups lives in the plain /api namespace like
    # every other board_group route. This alias keeps the /api/v1/ path working
    # so callers that followed the doc don't 404; both paths hit the same action.
    get "v1/board_groups/:id/graph", to: "board_groups#graph"
    get "sample_voices", to: "images#sample_voices"

    resources :generated_boards, param: :token, only: %i[create show] do
      member do
        post :claim
        get :pdf
      end
    end

    resources :boards do
      resources :images
      collection do
        get "predictive_index"
        get "user_boards"
        get "words"
        get "categories"
        get "initial_predictive_board"
        post "import_obf"
        post "analyze_obz"
        post "create_from_template"
        get "common_boards"
        get "list"
      end
      member do
        post "format_with_ai"
        post "save_layout"
        # get :print, defaults: { format: :html }
        get :pdf, defaults: { format: :pdf }
        post "generate_preview_image"
        post "rearrange_images"
        post "add_image"
        post "remove_image"
        put "associate_image"
        put "associate_images"
        post "clone"
        put "add_to_team"
        put "add_to_groups"
        post "assign_accounts"
        put "remove_from_team"
        get "predictive_image_board"
        get "additional_words"
        get "get_description"
        get "download_obf"
        put "update_preset_display_image"
        put "set_display_image"
        put "recategorize_images"
        put "update_to_default_docs"
        put "set_colors"
        post "regenerate_images"
        patch "make_editable"
      end
    end
    resources :board_images do
      member do
        post "create_variation", to: "board_images#create_image_variation"
        post "create_edit", to: "board_images#create_image_edit"
        post "upload_audio", to: "board_images#upload_audio"
        post "reset_audio", to: "board_images#reset_audio"
        post "set_current_audio", to: "board_images#set_current_audio"
        post "attach_youtube_video", to: "board_images#attach_youtube_video"
        post "upload_video", to: "board_images#upload_video"
        post "clear_video", to: "board_images#clear_video"
      end
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
    resources :coaching_prompts do
      collection do
        get "audio"
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

    post "delete_account", to: "users#delete_account"
    post "send_delete_account_email", to: "users#send_delete_account_email"

    resources :users do
      member do
        put "update_settings"
      end
    end

    resources :child_accounts do
      collection do
        # #439: owner picks which communicators stay signable when over the
        # plan's slot limit (the rest fall back to the public MySpeak page).
        post "keep_signable"
      end
      member do
        post "assign_boards"
        post "send_setup_email"
        # B3: promote sandbox → loaner. `lend` is the frontend-facing alias.
        post "promote_to_loaner"
        post "lend", to: "child_accounts#lend"
        # B4: claim flow controls for the SLP side.
        post "claim_link"
        post "send_claim_link"
        post "end_loan"
        # #165: soft-archive sandbox communicators
        post "archive"
        post "unarchive"
        delete "remove_board"
      end
    end

    # B4: parent-facing claim endpoints — fetched without auth (preview)
    # or with a signed-in parent (claim). Lives at its own namespace so
    # the URLs read naturally.
    get  "communicator_claims/:token", to: "child_accounts#claim_preview", as: :communicator_claim_preview
    post "communicator_claims/:token/claim", to: "child_accounts#claim", as: :communicator_claim

    resources :profiles do
      collection do
        get "placeholders"
        get "next_placeholder"
        get "public/:slug", to: "profiles#public"
        post "public/:slug/safety_view", to: "profiles#safety_view"
        get "check_slug", to: "profiles#check_slug"
        post "generate"
      end
    end
    get "profiles/:slug/check_placeholder", to: "profiles#check_placeholder"
    post "profiles/claim_placeholder", to: "profiles#claim_placeholder"

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

    namespace :internal do
      resources :boards, only: [:create, :update, :show] do
        collection do
          post :from_vocab_set
        end
        member do
          get :export, action: :export_pdf, defaults: { format: :pdf }
        end
        resources :board_images, only: [:create] do
          collection do
            post :bulk
          end
        end
      end
      resources :generated_boards, only: [:create]
      resources :images, only: [:create, :show] do
        collection do
          post :generate
          get :search
          post :search, action: :bulk_search
        end
      end
      resources :profiles, only: [:show, :update]

      # Hosted marketing PDFs (AAC Classroom Kit) addressed by a stable slug.
      resources :marketing_assets, only: [:create, :show], param: :slug

      # Generic (data-less) marketing printables rendered on demand.
      get "marketing_artifacts/name_tag",
          to: "marketing_artifacts#name_tag",
          defaults: { format: :pdf }
      get "marketing_artifacts/safety_tag",
          to: "marketing_artifacts#safety_tag",
          defaults: { format: :pdf }
      get "marketing_artifacts/device_tag",
          to: "marketing_artifacts#device_tag",
          defaults: { format: :pdf }
    end

    namespace :v1 do
      namespace :onboarding do
        post :myspeak, to: "myspeak#create"
      end

      # Board Builder wizard (hybrid: pick a starter template + add interests).
      get  "board_builder/templates",           to: "board_builder#templates"
      get  "board_builder/interest_categories", to: "board_builder#interest_categories"
      post "board_builder",                     to: "board_builder#create"

      resource :auth, only: [:create, :destroy]
      delete "/child_accounts/logout", to: "child_auths#destroy"
      post "/child_accounts/login", to: "child_auths#create"
      get "/child_accounts/current", to: "child_auths#current"
      get "users/current", to: "auths#current"
      post "users", to: "auths#sign_up"
      post "users/email_signup", to: "auths#email_signup"
      post "users/set_password", to: "auths#set_password"
      post "users/sign_in", to: "auths#create"
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
      resources :feedback, only: [:index]
      resources :users do
        member do
          post "send_welcome_email"
          post "send_setup_email"
          post "send_temp_login_email"
          post "send_partner_welcome_email"
          post "adjust_credits"
        end
        collection do
          delete "destroy_users"
          delete "cleanup_demo"
          get "export"
        end
      end
      resources :teams
      get "mission_control", to: "mission_control#show"
      get "word_events", to: "word_events#index", as: :word_events
      resources :boards do
        collection do
          get "generated_boards"
        end
      end
      resources :clinician_applications, only: [:index] do
        member do
          post "approve"
          post "deny"
        end
      end
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

  namespace :wix do
    post "submit", to: "application#submit"
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
  mount RailsPerformance::Engine, at: "rails/performance"

  # Catch-all route for handling 404 errors. This should be the last route in the file to ensure it catches all unmatched routes.
  match "*path", via: :all, to: "error#not_found"
end
