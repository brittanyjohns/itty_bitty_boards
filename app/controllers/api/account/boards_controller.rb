class API::Account::BoardsController < API::Account::ApplicationController
  # protect_from_forgery with: :null_session
  respond_to :json

  # before_action :authenticate_user!
  # skip_before_action :authenticate_child_token!, only: %i[show current]

  # layout "fullscreen", only: [:fullscreen]
  # layout "locked", only: [:locked]

  # GET /boards or /boards.json
  def index
    ActiveRecord::Base.logger.silence do
      if params[:query].present?
        @boards = Board.search_by_name(params[:query]).order(name: :asc).page params[:page]
        @predefined_boards = Board.predefined.search_by_name(params[:query]).order(name: :asc).page params[:page]
        render json: { boards: @boards, predefined_boards: @predefined_boards }
        return
      elsif params[:boards_only].present?
        @boards = current_account.boards.user_made_with_scenarios.order(name: :asc)
        @predefined_boards = Board.predefined.user_made_with_scenarios.order(name: :asc)
      else
        @boards = boards_for_user.user_made_with_scenarios.order(name: :asc)
        @predefined_boards = Board.predefined.user_made_with_scenarios.order(name: :asc)
      end

      # if current_account.admin?
      #   @boards = Board.all.order(name: :asc)
      # end

      @categories = @boards.map(&:category).uniq.compact
      @predictive_boards = current_account.boards.predictive.order(name: :asc)
      @category_boards = current_account.boards.categories(current_account.id).order(name: :asc)
      @dynamic_boards = current_account.boards.dynamic(current_account.id).order(name: :asc)
      # @boards = current_account.boards.all.order(name: :asc)

      render json: { boards: @boards, predefined_boards: @predefined_boards, categories: @categories, all_categories: Board.board_categories, predictive_boards: @predictive_boards, category_boards: @category_boards, dynamic_boards: @dynamic_boards }
    end
  end

  def preset
    ActiveRecord::Base.logger.silence do
      if params[:query].present?
        @predefined_boards = Board.predefined.search_by_name(params[:query]).order(name: :asc).page params[:page]
      elsif params[:filter].present?
        filter = params[:filter]
        unless Board::SAFE_FILTERS.include?(filter)
          render json: { error: "Invalid filter" }, status: :unprocessable_entity
          return
        end

        result = Board.predefined.send(filter)
        if result.is_a?(ActiveRecord::Relation)
          @predefined_boards = result.order(name: :asc).page params[:page]
        else
          @predefined_boards = result
        end
        # @predefined_boards = Board.predefined.where(category: params[:filter]).order(name: :asc).page params[:page]
      else
        @predefined_boards = Board.predefined.order(name: :asc)
      end
      @categories = @predefined_boards.map(&:category).uniq.compact
      @welcome_boards = Board.welcome
      render json: { predefined_boards: @predefined_boards, categories: @categories, all_categories: Board.board_categories, welcome_boards: @welcome_boards.map(&:api_view_with_images) }
    end
  end

  def categories
    @categories = Board.board_categories
    render json: @categories
  end

  def user_boards
    # @boards = boards_for_user.user_made_with_scenarios_and_menus.order(name: :asc)
    @boards = current_account.boards.user_made_with_scenarios.order(name: :asc)

    render json: { boards: @boards, dynamic_boards: current_account.dynamic_boards }
  end

  def predictive_index
    @boards = Board.with_artifacts.predictive
    @predictive_boards = @boards.map do |board|
      {
        id: board.id,
        name: board.name,
        description: board.description,
        can_edit: (board.user == current_account || current_account.admin?),
        parent_type: board.parent_type,
        predefined: board.predefined,
        number_of_columns: board.number_of_columns,
        images: board.board_images.map do |board_image|
          {
            id: board_image.image.id,
            label: board_image.image.label,
            image_prompt: board_image.image.image_prompt,
            bg_color: board_image.image.bg_class,
            text_color: board_image.image.text_color,
            next_words: board_image.next_words,
            position: board_image.position,
            src: board_image.image.display_image_url(current_account),
            audio: board_image.audio_url,
          }
        end,
      }
    end
    render json: @predictive_boards
  end

  def predictive_image_board
    @board = Board.with_artifacts.find_by(id: params[:id])
    @board = Board.with_artifacts.find_by(slug: params[:id]) unless @board
    if @board.nil?
      @board = Board.predictive_default(current_account)
      Rails.logger.info "#{Board.predictive_default_id} -- No user predictive default board found - setting default board : #{@board.id}"
      current_account.settings["dynamic_board_id"] = nil
      current_account.save!
    end
    # expires_in 8.hours, public: true # Cache control header

    if stale?(etag: @board, last_modified: @board.updated_at)
      RailsPerformance.measure("Predictive Image Board") do
        # @loaded_board = Board.with_artifacts.find(@board.id)
        @board_with_images = @board.api_view_with_predictive_images(current_account)
      end
      render json: @board_with_images
    end

    # render json: @board.api_view_with_predictive_images(current_account)
  end

  def show
    # board = Board.with_artifacts.find(params[:id])
    set_board
    user_permissions = {
      can_edit: (@board.user == current_account || current_account.admin?),
      can_delete: (@board.user == current_account || current_account.admin?),
    }
    if stale?(etag: @board, last_modified: @board.updated_at)
      RailsPerformance.measure("Show Board") do
        # @loaded_board = Board.with_artifacts.find(@board.id)
        @board_with_images = @board.api_view_with_predictive_images(current_account)
      end
      render json: @board_with_images.merge(user_permissions)
    end
  end

  def initial_predictive_board
    opening_board_id = current_account&.settings["opening_board_id"] ? current_account.settings["opening_board_id"].to_i : nil
    @board = Board.find_by(id: opening_board_id) if opening_board_id

    if @board.nil?
      # @board = Board.predictive_default(current_account)
      # CreateCustomPredictiveDefaultJob.perform_async(current_account.id)
      # current_account.settings["dynamic_board_id"] = nil
      # current_account.save!
      @board = current_account.boards.first
    end
    render json: @board.api_view_with_predictive_images(current_account)
  end

  private

  # Use callbacks to share common setup or constraints between actions.
  def set_board
    # ActiveRecord::Base.logger.silence do
    @board = Board.with_artifacts.find(params[:id])
    # end
  end

  def boards_for_user
    current_account.boards.with_artifacts
  end

  def image_params
    params.require(:image).permit(:label, :image_prompt, :display_image, audio_files: [], docs: [:id, :user_id, :image, :documentable_id, :documentable_type, :processed, :_destroy])
  end

  # Only allow a list of trusted parameters through.
  def board_params
    params.require(:board).permit(:user_id,
                                  :name,
                                  :parent_id,
                                  :parent_type,
                                  :description,
                                  :predefined,
                                  :number_of_columns,
                                  :voice,
                                  :small_screen_columns,
                                  :medium_screen_columns,
                                  :large_screen_columns,
                                  :next_words,
                                  :images,
                                  :layout,
                                  :image_ids,
                                  :image_id,
                                  :query,
                                  :page,
                                  :display_image_url, :category, :word_list, :image_ids_to_remove, :board_type)
  end
end
