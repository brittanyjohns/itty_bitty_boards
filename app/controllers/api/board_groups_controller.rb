class API::BoardGroupsController < API::ApplicationController
  skip_before_action :authenticate_token!, only: %i[ preset index ]

  def index
    @featured_board_groups = BoardGroup.featured.alphabetical.page params[:page]
    @board_groups = current_user.board_groups.where(predefined: [false, nil])
    @predefined = BoardGroup.predefined
    render json: { predefined: @predefined.map(&:api_view), user: @board_groups.map(&:api_view), featured: @featured_board_groups.map(&:api_view) }
  end

  def preset
    ActiveRecord::Base.logger.silence do
      if params[:query].present?
        @predefined_board_groups = BoardGroup.predefined.search_by_name(params[:query]).alphabetical.page params[:page]
      else
        @predefined_board_groups = BoardGroup.predefined.alphabetical.page params[:page]
      end
      @featured_board_groups = BoardGroup.featured.alphabetical.page params[:page]
      @user_board_groups = current_user.board_groups.where(predefined: [false, nil]).alphabetical.page params[:page]
      puts "Featured Board Groups: #{@featured_board_groups.count}"
      @welcome_board = @welcome_group&.boards&.first
      render json: { predefined_board_groups: @predefined_board_groups.map(&:api_view), featured_board_groups: @featured_board_groups.map(&:api_view), welcome_board: @welcome_board&.api_view, user_board_groups: @user_board_groups.map(&:api_view) }
    end
  end

  def show
    @board_group = BoardGroup.includes(board_group_boards: :board).find_by(id: params[:id]) if params[:id].present?
    @board_group = BoardGroup.includes(board_group_boards: :board).find_by(slug: params[:id]) if params[:id].present? && @board_group.nil?
    unless @board_group
      render json: { error: "Board Group not found" }, status: :not_found
      return
    end

    render json: @board_group.api_view_with_boards(current_user)
  end

  def show_by_slug
    puts "Finding Board Group by slug: #{params[:slug]}"
    @board_group = BoardGroup.includes(board_group_boards: :board).find_by(slug: params[:slug])
    if @board_group
      render json: @board_group.api_view_with_boards(current_user)
    else
      render json: { error: "Board Group not found" }, status: :not_found
    end
  end

  def create
    board_group = BoardGroup.new
    board_group.user = current_user
    board_group.predefined = board_group_params[:predefined]
    board_group.number_of_columns = board_group_params[:number_of_columns]
    board_group.featured = board_group_params[:featured] || false
    screen_size = board_group_params[:screen_size] || "lg"
    boards = board_group_params[:board_ids].map { |id| Board.find_by(id: id) if id.present? }.compact
    boards.each do |board|
      board_group_board = board_group.add_board(board)
      board_group_board.save!
    end

    if board_group.save
      mark_default(board_group)
      board_group.calculate_grid_layout_for_screen_size(screen_size)
      render json: board_group.api_view_with_boards(current_user)
    else
      render json: { errors: board_group.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def rearrange_boards
    board_group = BoardGroup.find(params[:id])
    screen_size = params[:screen_size] || "lg"
    board_group.calculate_grid_layout_for_screen_size(screen_size)
    board_group.save
    render json: board_group.api_view_with_boards(current_user)
  end

  def save_layout
    @board_group = BoardGroup.find(params[:id])
    save_layout!

    @board_group.reload
    render json: @board_group.api_view_with_boards(current_user)
  end

  def remove_board
    board_group = BoardGroup.find(params[:id])
    board = Board.find(params[:board_id])
    board_group_boards = board_group.board_group_boards.find_by(board: board)
    if board_group_boards.nil?
      render json: { error: "Board not found in this group" }, status: :not_found
      return
    end
    puts "Removing board #{board.id} from group #{board_group.id}"
    puts "Board Group Boards: #{board_group.board_group_boards.count}"
    board_group_boards.destroy
    board_group.reload
    puts "Board Group Boards after removal: #{board_group.board_group_boards.count}"
    render json: board_group.api_view_with_boards(current_user)
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Board or Board Group not found" }, status: :not_found
  end

  def update
    board_group = BoardGroup.find(params[:id])
    board_group.predefined = board_group_params[:predefined]
    board_group.number_of_columns = board_group_params[:number_of_columns]
    board_group.featured = board_group_params[:featured] || false
    boards = board_group_params[:board_ids].map { |id| Board.find_by(id: id) if id.present? }.compact
    boards.each do |board|
      board_group_board = board_group.add_board(board)
      board_group_board.save!
    end
    if board_group.save
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
    params.require(:board_group).permit(:name, :featured, :display_image_url, :predefined, :number_of_columns, :small_screen_columns, :medium_screen_columns, :large_screen_columns, board_ids: [])
  end

  def mark_default(board_group)
    make_default = current_user.board_groups.empty? || board_group_params[:make_default]
    if make_default
      current_user.settings["startup_board_group_id"] = board_group.id
      current_user.save
    end
  end

  def save_layout!
    layout = params[:layout].map(&:to_unsafe_h) # Convert ActionController::Parameters to a Hash

    # Sort layout by y and x coordinates
    sorted_layout = layout.sort_by { |item| [item["y"].to_i, item["x"].to_i] }

    board_group_board_ids = []
    sorted_layout.each_with_index do |item, i|
      board_group_board_id = item["i"].to_i
      board_group_board = @board_group.board_group_boards.find_by(id: board_group_board_id)
      if board_group_board
        puts "Updating position for board group board ID: #{board_group_board_id} to #{i}"
        board_group_board.update!(position: i)
      else
        Rails.logger.error "Board group board not found for ID: #{board_group_board_id}"
      end
    end

    # Save screen size settings
    screen_size = params[:screen_size] || "lg"
    if params[:small_screen_columns].present? || params[:medium_screen_columns].present? || params[:large_screen_columns].present?
      @board_group.small_screen_columns = params[:small_screen_columns].to_i if params[:small_screen_columns].present?
      @board_group.medium_screen_columns = params[:medium_screen_columns].to_i if params[:medium_screen_columns].present?
      @board_group.large_screen_columns = params[:large_screen_columns].to_i if params[:large_screen_columns].present?
    end

    # Save margin settings
    margin_x = params[:xMargin].to_i
    margin_y = params[:yMargin].to_i
    if margin_x.present? && margin_y.present?
      @board_group.margin_settings[screen_size] = { x: margin_x, y: margin_y }
    end

    # Save additional settings
    @board_group.settings[screen_size] = params[:settings] if params[:settings].present?
    @board_group.save!

    # Update the grid layout
    begin
      @board_group.update_grid_layout(sorted_layout, screen_size)
    rescue => e
      Rails.logger.error "Error updating grid layout: #{e.message}\n#{e.backtrace.join("\n")}"
    end
    @board_group.reload
  end
end
