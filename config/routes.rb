Rails.application.routes.draw do
  resources :menus
  resources :docs do
    member do
      patch "mark_as_current"
    end
  end
  resources :board_images
  resources :images do
    member do
      post "generate"
    end
  end

  resources :boards do
    member do
      get "build"
      post "add_multiple_images"
      post "associate_image"
      post "remove_image"
    end
  end
  devise_for :users
  get 'main/index'
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Defines the root path route ("/")
  root "main#index"
end
