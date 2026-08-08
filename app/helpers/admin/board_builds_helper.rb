module Admin
  module BoardBuildsHelper
    # The board as it opens in the app. Unlike the /pb/ public page this works
    # before the board is published, which is exactly when an admin is
    # reviewing a fresh build.
    def board_app_url(board)
      "#{front_end_base_url}/boards/#{board.id}"
    end

    # Only meaningful once the board is published — /pb/ 404s before that.
    def board_published_page_url(board)
      "#{front_end_base_url}/pb/#{board.slug}"
    end

    private

    def front_end_base_url
      ENV["FRONT_END_URL"] || "http://localhost:8100"
    end
  end
end
