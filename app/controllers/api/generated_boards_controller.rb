class API::GeneratedBoardsController < API::ApplicationController
  skip_before_action :authenticate_token!, only: %i[create show pdf]
  before_action :set_generated_board_by_token, only: %i[show claim pdf]
  WORD_COUNT_OPTIONS = [9, 12, 16, 20, 24, 30, 36, 42, 48, 54, 60].freeze

  # POST /api/generated_boards
  def create
    topic = params[:topic].to_s.strip
    age_range = params[:ageRange].presence || params[:age_range].presence
    word_count = params[:wordCount].presence || params[:word_count].presence || 12
    board_name = params[:name].presence || generated_board_name(topic, age_range)
    if topic.blank?
      render json: { error: "Topic is required" }, status: :unprocessable_entity
      return
    end
    now = Time.now
    generated_token_expires_at = now + 2.days

    begin
      board = Board.new(
        user: nil,
        generated_token_expires_at: generated_token_expires_at,
        generated_token: SecureRandom.hex(16),
        name: board_name,
      )
      columns = ideal_columns_for(word_count.to_i)
      board.large_screen_columns = columns
      board.medium_screen_columns = columns
      board.small_screen_columns = columns / 2
      board.settings = {
        disable_scroll: true,
      }

      board.board_type = "generated"
      board.assign_parent
      new_slug = board.generate_unique_slug
      board.slug = new_slug
      board.voice = "polly:kevin"
      board.status = "generating"
      if board.save
        GenerateFreeBoardJob.perform_async(board.id, topic, age_range, word_count.to_i)

        render json: {
                 id: board.id,
                 name: board.name,
                 generated_token: board.generated_token,
               }, status: :created
      else
        Rails.logger.error("GeneratedBoardsController#create failed to save board #{board.id}: #{board.errors.full_messages.join(", ")}")
        render json: { error: board.errors.full_messages.join(", ") }, status: :unprocessable_entity
      end
    rescue => e
      Rails.logger.error("GeneratedBoardsController#create failed for board #{board.id}: #{e.class} - #{e.message}")
      board.destroy if board.persisted?
      render json: { error: "Unable to generate board" }, status: :unprocessable_entity
    end
  end

  # GET /api/generated_boards/:token
  def show
    render json: @board.api_view_with_images(current_user)
  end

  # POST /api/generated_boards/:token/claim
  def claim
    unless current_user
      render json: { error: "You must be logged in to claim a board" }, status: :unauthorized
      return
    end
    current_user.boards.reload
    user_board_count = current_user.boards.where(predefined: false).count
    if user_board_count >= current_user.board_limit
      render json: { error: "Maximum number of boards reached (#{user_board_count}/#{current_user.board_limit}). Please upgrade to add more." }, status: :unprocessable_entity
      return
    end

    if !@board.generated?
      render json: { error: "This board is not claimable" }, status: :unprocessable_entity
      return
    end

    if @board.user_id.present? && @board.user_id != current_user.id
      render json: { error: "This board has already been claimed" }, status: :forbidden
      return
    end

    @board.update!(
      user: current_user,
      generated_token_expires_at: nil,
      generated_token: nil,
    )

    render json: {
      success: true,
      id: @board.id,
      name: @board.name,
      slug: @board.slug,
    }
  end

  # GET /api/generated_boards/:token/pdf
  def pdf
    # Reuse your existing board PDF logic by loading @board
    # If your app already has a BoardsController#pdf action, the cleanest move
    # is to redirect to it with the real board id.

    redirect_to pdf_api_board_url(
      @board,
      screen_size: params[:screen_size] || "lg",
      hide_colors: params[:hide_colors] || "0",
      hide_header: params[:hide_header] || "0",
    )
  end

  private

  def set_generated_board_by_token
    @board = Board.find_by!(generated_token: params[:token])
  rescue ActiveRecord::RecordNotFound
    render json: { error: "Generated board not found" }, status: :not_found
  end

  def generated_board_name(topic, age_range)
    base_name = topic.presence || "Generated Board"
    age_part = age_range.present? ? " (Age Range: #{age_range})" : ""
    "#{base_name}#{age_part}"
  end

  def generator_board_view(board)
    # If you already have a normal API board serializer/view method,
    # use it here instead of duplicating logic.

    api_board = board.respond_to?(:api_view) ? board.api_view(nil) : {}

    api_board.merge(
      id: board.id,
      name: board.name,
      generated_token: board.generated_token,
      generated_token_expires_at: board.generated_token_expires_at,
      pdf_url: api_pdf_generated_board_url(
        board.generated_token,
        screen_size: params[:screen_size] || "lg",
        hide_colors: params[:hide_colors] || "0",
        hide_header: params[:hide_header] || "0",
      ),
    )
  end

  # const WORD_COUNT_OPTIONS = [
  #   9, 12, 16, 20, 24, 30, 36, 42, 48, 54, 60, 72, 84, 96,
  # ];

  def ideal_columns_for(word_count)
    # return most evenly distributed column count based on word count, with a max of 12 columns for large screens
    # 96 words would be 12 columns with 8 rows, 72 words would be 9 columns with 8 rows, 60 words would be 10 columns with 6 rows, 54 words would be 9 columns with 6 rows, 48 words would be 8 columns with 6 rows, 42 words would be 7 columns with 6 rows, 36 words would be 6 columns with 6 rows, 30 words would be 6 columns with 5 rows, 24 words would be 6 columns with 4 rows, 20 words would be 5 columns with 4 rows, 16 words would be 4 columns with 4 rows, 12 words would be 4 columns with 3 rows, and 9 words would be 3 columns with 3 rows
    case word_count
    when 0..9
      3
    when 10..12
      4
    when 13..16
      4
    when 17..20
      5
    when 21..24
      6
    when 25..30
      6
    when 31..36
      6
    when 37..42
      7
    when 43..48
      8
    when 49..54
      9
    when 55..60
      10
    else
      [12, (word_count / 8.0).ceil].min # Max of 12 columns, or enough to fit words in rows of ~8
    end
  end
end
