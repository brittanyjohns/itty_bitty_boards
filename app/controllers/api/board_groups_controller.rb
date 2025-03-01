class API::BoardGroupsController < API::ApplicationController
  skip_before_action :authenticate_token!, only: %i[ preset ]

  def index
    @board_groups = current_user.board_groups.where(predefined: [false, nil])
    @predefined = BoardGroup.predefined
    render json: { predefined: @predefined.map(&:api_view_with_boards), user: @board_groups.map(&:api_view_with_boards) }
  end

  def preset
    ActiveRecord::Base.logger.silence do
      if params[:query].present?
        @predefined_board_groups = BoardGroup.predefined.search_by_name(params[:query]).order(created_at: :desc).page params[:page]
      else
        @predefined_board_groups = BoardGroup.predefined.order(created_at: :desc).page params[:page]
      end
      @welcome_group = BoardGroup.welcome_group
      @welcome_board = @welcome_group&.boards&.first
      puts "Welcome group: #{@welcome_group}"
      render json: { predefined_board_groups: @predefined_board_groups.map(&:api_view_with_boards), welcome_group: @welcome_group&.api_view_with_boards, welcome_board: @welcome_board&.api_view_with_images }
    end
  end

  def show
    @board_group = BoardGroup.find(params[:id])

    render json: @board_group.api_view_with_boards(current_user)
  end

  def create
    board_group = BoardGroup.new(board_group_params)
    board_group.user = current_user
    board_group.predefined = board_group_params[:predefined]
    board_group.number_of_columns = board_group_params[:number_of_columns]

    if board_group.save
      mark_default(board_group)
      board_group.calculate_grid_layout
      render json: board_group.api_view_with_boards(current_user)
    else
      render json: { errors: board_group.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def rearrange_boards
    board_group = BoardGroup.find(params[:id])
    board_group.calculate_grid_layout
    board_group.save
    render json: board_group.api_view_with_boards(current_user)
  end

  def save_layout
    board_group = BoardGroup.find(params[:id])
    layout = params[:layout]
    layout.each_with_index do |layout_item, index|
      board_id = layout_item["i"]
      puts "Board ID: #{board_id}"
      if board_id.blank?
        puts "Skipping blank board ID at index #{index}"
        next
      end
      board = board_group.boards.find(board_id.to_i)
      board.group_layout = layout_item
      board.save!
    end
    board_group.reload
    render json: board_group.api_view_with_boards(current_user)
  end

  def remove_board
    board_group = BoardGroup.find(params[:id])
    board = Board.find(params[:board_id])
    board_group.boards.delete(board)
    render json: board_group.api_view_with_boards(current_user)
  end

  def update
    board_group = BoardGroup.find(params[:id])
    board_group.predefined = board_group_params[:predefined]
    board_group.number_of_columns = board_group_params[:number_of_columns]
    if board_group.update(board_group_params)
      mark_default(board_group)
      board_group.adjust_layouts
      render json: board_group.api_view_with_boards(current_user)
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
    params.require(:board_group).permit(:name, :display_image_url, :make_default, :predefined, :number_of_columns, board_ids: [])
  end

  def mark_default(board_group)
    make_default = current_user.board_groups.empty? || board_group_params[:make_default]
    if make_default
      current_user.settings["startup_board_group_id"] = board_group.id
      current_user.save
    end
  end
end
