class API::BoardGroupsController < API::ApplicationController
  def index
    @board_groups = current_user.board_groups.where(predefined: false)
    @predefined = BoardGroup.predefined
    puts "predefined: #{@predefined.map(&:api_view_with_boards)}"
    puts "user: #{@board_groups.map(&:api_view_with_boards)}"
    render json: { predefined: @predefined.map(&:api_view_with_boards), user: @board_groups.map(&:api_view_with_boards) }
  end

  def show
    @board_group = BoardGroup.find(params[:id])
    render json: @board_group.api_view_with_boards(current_user)
  end

  def create
    puts "board_group_params: #{board_group_params}"
    board_group = BoardGroup.new(board_group_params)
    board_group.user = current_user

    if board_group.save
      board_group.calucate_grid_layout
      render json: board_group.api_view_with_boards(current_user)
    else
      render json: { errors: board_group.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def rearrange_boards
    board_group = BoardGroup.find(params[:id])
    board_group.calucate_grid_layout
    board_group.save
    render json: board_group.api_view_with_boards(current_user)
  end

  def save_layout
    board_group = BoardGroup.find(params[:id])
    layout = params[:layout]
    layout.each_with_index do |layout_item, index|
      board_id = layout_item["i"]
      board = board_group.boards.find(board_id)
      board.layout = layout_item
      board.save!
    end
    board.reload
    render json: board.api_view_with_images(current_user)
  end

  def remove_board
    board_group = BoardGroup.find(params[:id])
    board = Board.find(params[:board_id])
    board_group.boards.delete(board)
    render json: board_group.api_view_with_boards(current_user)
  end

  def update
    board_group = BoardGroup.find(params[:id])

    puts "\nUPDATE\nboard_group_params: #{board_group_params}"
    board_group.predefined = board_group_params[:predefined]
    puts "board_group.predefined: #{board_group.predefined}"
    board_group.number_of_columns = board_group_params[:number_of_columns]
    puts "board_group.number_of_columns: #{board_group.number_of_columns}"

    if board_group.update(board_group_params)
      # board_group.calucate_grid_layout
      render json: board_group
    else
      render json: { errors: board_group.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    board_group = BoardGroup.find(params[:id])
    board_group.destroy

    render json: { message: "Board Group deleted" }
  end

  private

  def board_group_params
    params.require(:board_group).permit(:name, :display_image_url, :predefined, :number_of_columns, board_ids: [])
  end
end
