module Admin
  class ApplicationController < ApplicationController
    layout "admin"

    before_action :authenticate_user!
    before_action :require_admin!

    # Same net as the JSON side: an admin action that reaches a board frozen by
    # a marketplace listing gets the explanation, not a 500.
    rescue_from Board::MarketplaceProtectedError do |e|
      redirect_back(
        fallback_location: root_path,
        alert: "\"#{e.board.name}\" is sold as a printable and can't be #{e.action}. Release protection on the printable first.",
      )
    end

    private

    def require_admin!
      unless current_user&.admin?
        redirect_to root_path, alert: "Not authorized."
      end
    end
  end
end
