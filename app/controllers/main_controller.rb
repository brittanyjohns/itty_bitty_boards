class MainController < ApplicationController
  skip_before_action :authenticate_user!, only: [:index]
  def index
    @docs = current_user.docs
  end
end
