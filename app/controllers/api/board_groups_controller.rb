class API::BoardGroupsController < API::ApplicationController
  skip_before_action :authenticate_token!, only: %i[ preset index ]

  def index
    @featured_board_groups = BoardGroup.featured.order(created_at: :desc).page params[:page]
    @board_groups = current_user.board_groups.where(predefined: [false, nil])
    @predefined = BoardGroup.predefined
    render json: { predefined: @predefined.map(&:api_view), user: @board_groups.map(&:api_view), featured: @featured_board_groups.map(&:api_view) }
  end

  def preset
    ActiveRecord::Base.logger.silence do
      if params[:query].present?
        @predefined_board_groups = BoardGroup.predefined.search_by_name(params[:query]).order(created_at: :desc).page params[:page]
      else
        @predefined_board_groups = BoardGroup.predefined.order(created_at: :desc).page params[:page]
      end
      @featured_board_groups = BoardGroup.featured.order(created_at: :desc).page params[:page]
      puts "Featured Board Groups: #{@featured_board_groups.count}"
      @welcome_board = @welcome_group&.boards&.first
      render json: { predefined_board_groups: @predefined_board_groups.map(&:api_view), featured_board_groups: @featured_board_groups.map(&:api_view), welcome_board: @welcome_board&.api_view }
    end
  end

  def show
    @board_group = BoardGroup.find_by(id: params[:id]) if params[:id].present?
    @board_group = BoardGroup.find_by(slug: params[:id]) if params[:id].present? && @board_group.nil?
    unless @board_group
      render json: { error: "Board Group not found" }, status: :not_found
      return
    end

    render json: @board_group.api_view_with_boards(current_user)
  end

  def show_by_slug
    puts "Finding Board Group by slug: #{params[:slug]}"
    @board_group = BoardGroup.find_by(slug: params[:slug])
    if @board_group
      render json: @board_group.api_view_with_boards(current_user)
    else
      render json: { error: "Board Group not found" }, status: :not_found
    end
  end

  def create
    board_group = BoardGroup.new(board_group_params)
    board_group.user = current_user
    board_group.predefined = board_group_params[:predefined]
    board_group.number_of_columns = board_group_params[:number_of_columns]
    board_group.featured = board_group_params[:featured] || false

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
    board_group.featured = board_group_params[:featured] || false
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
    params.require(:board_group).permit(:name, :featured, :display_image_url, :predefined, :number_of_columns, board_ids: [])
  end

  def mark_default(board_group)
    make_default = current_user.board_groups.empty? || board_group_params[:make_default]
    if make_default
      current_user.settings["startup_board_group_id"] = board_group.id
      current_user.save
    end
  end
end
