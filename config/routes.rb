require 'sidekiq/web'

Rails.application.routes.draw do
  resources :menus
  resources :docs do
    member do
      patch "mark_as_current"
    end
  end
  resources :board_images
  resources :images do
    get "menu", on: :collection
    post "find_or_create", on: :collection
    member do
      post "generate"
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
    end
  end
  # Order matters here.  users needs to be below the devise_for :users
  devise_for :users
  resources :users

  get 'main/index', as: :home
  get 'main/demo', as: :demo
  get 'main/about', as: :about
  get 'main/contact', as: :contact
  get 'main/faq', as: :faq
  get 'main/welcome', as: :user_root

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
