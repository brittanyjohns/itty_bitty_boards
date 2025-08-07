class API::BoardGroupsController < API::ApplicationController
  skip_before_action :authenticate_token!, only: %i[ preset index show show_by_slug ]

  def index
    @featured_board_groups = BoardGroup.featured.alphabetical.page params[:page]
    @board_groups = current_user.board_groups.where(predefined: [false, nil])
    @predefined = BoardGroup.predefined
    @all = @board_groups + @predefined
    render json: { predefined: @predefined.map(&:api_view), user: @board_groups.map(&:api_view), featured: @featured_board_groups.map(&:api_view), all: @all.map(&:api_view) }
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
      Rails.logger.debug "Featured Board Groups: #{@featured_board_groups.count}"
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
    Rails.logger.debug "Finding Board Group by slug: #{params[:slug]}"
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
    board_group.small_screen_columns = board_group_params[:small_screen_columns] || 1
    board_group.medium_screen_columns = board_group_params[:medium_screen_columns] || 2
    board_group.large_screen_columns = board_group_params[:large_screen_columns] || 3
    board_group.settings = board_group_params[:settings] || {}
    board_group.margin_settings = board_group_params[:margin_settings] || {}
    board_group.name = board_group_params[:name]
    board_group.display_image_url = board_group_params[:display_image_url]
    board_group.description = board_group_params[:description] if board_group_params[:description].present?
    Rails.logger.debug "display_image_url: #{board_group.display_image_url.inspect}"
    screen_size = board_group_params[:screen_size] || "lg"
    boards = board_group_params[:board_ids].map { |id| Board.find_by(id: id) if id.present? }.compact if board_group_params[:board_ids].present?
    Rails.logger.debug "Creating Board Group with parameters: #{board_group_params.inspect}"
    board_group.save!
    if boards.blank?
      Rails.logger.debug "No boards provided, saving empty board group"
    else
      boards.each do |board|
        board_group_board = board_group.add_board(board)
        board_group_board.save!
      end
    end

    if board_group.save
      mark_default(board_group)
      # board_group.calculate_grid_layout_for_screen_size(screen_size)
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
    Rails.logger.debug "Removing board #{board.id} from group #{board_group.id}"
    Rails.logger.debug "Board Group Boards: #{board_group.board_group_boards.count}"
    board_group_boards.destroy
    board_group.reload
    Rails.logger.debug "Board Group Boards after removal: #{board_group.board_group_boards.count}"
    render json: board_group.api_view_with_boards(current_user)
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Board or Board Group not found" }, status: :not_found
  end

  def update
    board_group = BoardGroup.find(params[:id])
    Rails.logger.debug "Updating parameters: #{params.inspect}"
    board_group.predefined = board_group_params[:predefined]
    board_group.number_of_columns = board_group_params[:number_of_columns]
    board_group.featured = board_group_params[:featured] || false
    board_group.small_screen_columns = board_group_params[:small_screen_columns] || 4
    board_group.medium_screen_columns = board_group_params[:medium_screen_columns] || 5
    board_group.large_screen_columns = board_group_params[:large_screen_columns] || 6
    board_group.name = board_group_params[:name]
    board_group.description = board_group_params[:description] if board_group_params[:description].present?
    Rails.logger.debug "Parameters settings: #{board_group_params[:settings].inspect}"

    board_group.settings = board_group_params[:settings] || {}
    board_group.margin_settings = board_group_params[:margin_settings] || {}
    boards = board_group_params[:board_ids].map { |id| Board.find_by(id: id) if id.present? }.compact if board_group_params[:board_ids].present?
    Rails.logger.debug "Boards to add: #{boards.map(&:id).inspect}" if boards.present?
    Rails.logger.debug "Board Group before update: #{board_group.inspect}"
    display_image_url = params[:display_image_url] || board_group_params[:display_image_url]
    update_boards = params[:update_boards] || board_group_params[:update_boards]
    Rails.logger.debug "Update boards: #{update_boards.inspect}"
    if display_image_url.present? && !update_boards
      Rails.logger.debug "Setting display_image_url: #{display_image_url.inspect} - #{update_boards.inspect}"
      board_group.display_image_url = display_image_url
    else
      existing_board_ids = board_group.board_group_boards.map(&:board_id)
      boards_to_remove = []
      board_ids = board_group_params[:board_ids] || []
      board_group.board_group_boards.each do |bgb|
        if board_ids.exclude?(bgb.board_id.to_s)
          bgb.destroy
          boards_to_remove << bgb.board_id
        end
      end
      Rails.logger.debug "Boards to remove: #{boards_to_remove.inspect}"
      boards.each do |board|
        if board_group.boards.exclude?(board)
          Rails.logger.debug "Adding board #{board.id} to group #{board_group.id}"
          board_group_board = board_group.add_board(board)
          if board_group_board
            board_group_board.save!
          else
            Rails.logger.error "Failed to add board #{board.id} to group #{board_group.id}"
          end
        else
          Rails.logger.debug "Board #{board.id} already in group #{board_group.id}"
        end
      end
    end
    if board_group.save
      mark_default(board_group)
      save_layout! if params[:layout].present?
      Rails.logger.debug "Board Group updated successfully: #{board_group.id}"
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
    params.require(:board_group).permit(:name, :featured, :description, :display_image_url, :predefined, :number_of_columns, :small_screen_columns, :medium_screen_columns, :large_screen_columns, board_ids: [], settings: {}, margin_settings: {}, make_default: [true, false], screen_size: [:lg, :md, :sm], layout: [])
  end

  def mark_default(board_group)
    make_default = current_user.board_groups.empty? || board_group_params[:make_default]
    if make_default
      current_user.settings["startup_board_group_id"] = board_group.id
      current_user.save
    end
  end

  def save_layout!
    if params[:layout].blank?
      Rails.logger.debug "No layout provided, skipping layout save"
      return
    end
    if params[:layout].is_a?(Array)
      layout = params[:layout]
    elsif params[:layout].is_a?(ActionController::Parameters)
      layout = params[:layout].to_unsafe_h
    else
      Rails.logger.error "Invalid layout format: #{params[:layout].class}"
      render json: { error: "Invalid layout format" }, status: :unprocessable_entity and return
    end

    Rails.logger.debug "Received layout: #{layout.inspect}"

    # Sort layout by y and x coordinates
    sorted_layout = layout.sort_by { |item| [item["y"].to_i, item["x"].to_i] }

    board_group_board_ids = []
    sorted_layout.each_with_index do |item, i|
      board_group_board_id = item["i"].to_i
      board_group_board = @board_group.board_group_boards.find_by(id: board_group_board_id)
      if board_group_board
        Rails.logger.debug "Updating position for board group board ID: #{board_group_board_id} to #{i}"
        bgb_layout = {
          "x" => item["x"].to_i,
          "y" => item["y"].to_i,
          "w" => item["w"].to_i,
          "h" => item["h"].to_i,
        }
        board_group_board.group_layout ||= {}
        board_group_board.group_layout[params[:screen_size] || "lg"] = bgb_layout
        board_group_board.save!
        board_group_board_ids << board_group_board_id
        Rails.logger.debug "Board group board ID: #{board_group_board_id} updated with layout #{bgb_layout.inspect}"
        # Update position
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
