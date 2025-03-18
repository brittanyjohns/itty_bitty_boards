require "csv"

class API::Admin::BoardsController < API::Admin::ApplicationController
  def index
    @boards = Board.all

    respond_to do |format|
      format.json { render json: @boards }
      format.csv do
        send_data generate_csv(@boards), filename: "boards-#{Date.today}.csv"
      end
    end
  end

  private

  def generate_csv(boards)
    CSV.generate(headers: true) do |csv|
      csv << ["Board Name", "Type", "Parent Type", "Settings", "Word Count"]

      boards.each do |board|
        csv << [board.name, board.board_type, board.parent_type, board.settings, board.board_images_count]
      end
    end
  end
end
