require 'sidekiq/web'

Rails.application.routes.draw do
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
    end
  end
  # resources :board_images
  resources :images do
    get "menu", on: :collection
    post "find_or_create", on: :collection
    member do
      post "generate"
      post "add_to_board"
      post "create_symbol"
    end
  end

  resources :boards do
    member do
      get "build"
      get "fullscreen"
      post "clone"
      post "add_multiple_images"
      post "associate_image"
      post "remove_image"
      post "update_grid"
    end
  end
  # Order matters here.  users needs to be below the devise_for :users
  devise_for :users
  resources :users do
    member do
      delete "remove_user_doc"
    end
  end

  get 'main/index', as: :home
  get 'main/predefined/:id', to: 'main#show_predefined', as: :show_predefined
  get 'main/demo', as: :demo
  get 'main/about', as: :about
  get 'main/contact', as: :contact
  get 'main/welcome', as: :welcome
  get 'main/faq', as: :faq
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

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  mount Sidekiq::Web => '/sidekiq'

  # Defines the root path route ("/")
  root "main#index"
end
