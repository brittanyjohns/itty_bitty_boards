class API::Internal::GeneratedBoardsController < API::Internal::ApplicationController
  WORD_COUNT_OPTIONS = [9, 12, 16, 20, 24, 30, 36, 42, 48, 54, 60].freeze

  def create
    topic     = params[:topic].to_s.strip
    age_range = params[:ageRange].presence || params[:age_range].presence
    word_count = (params[:wordCount].presence || params[:word_count].presence || 12).to_i
    board_name = params[:name].presence || generated_board_name(topic, age_range)

    if topic.blank?
      render json: { error: "Topic is required" }, status: :unprocessable_entity
      return
    end

    board = nil
    begin
      board = Board.new(user: current_user, name: board_name)
      columns = ideal_columns_for(word_count)
      board.large_screen_columns  = columns
      board.medium_screen_columns = columns
      board.small_screen_columns  = columns / 2
      board.settings = { disable_scroll: true }
      board.assign_parent
      # assign_parent overwrites board_type to "static" for User-owned boards;
      # set it back so this board is identifiable as AI-generated.
      board.board_type = "generated"
      board.slug = board.generate_unique_slug
      board.voice  = "polly:kevin"
      board.status = "generating"

      if board.save
        GenerateFreeBoardJob.perform_async(board.id, topic, age_range, word_count)
        render json: { id: board.id, name: board.name, status: board.status }, status: :created
      else
        Rails.logger.error("API::Internal::GeneratedBoardsController#create save failed: #{board.errors.full_messages.join(", ")}")
        render json: { error: board.errors.full_messages.join(", ") }, status: :unprocessable_entity
      end
    rescue => e
      Rails.logger.error("API::Internal::GeneratedBoardsController#create raised: #{e.class} - #{e.message}")
      board.destroy if board&.persisted?
      render json: { error: "Unable to generate board" }, status: :unprocessable_entity
    end
  end

  private

  def generated_board_name(topic, age_range)
    base = topic.presence || "Generated Board"
    age_range.present? ? "#{base} (Age Range: #{age_range})" : base
  end

  def ideal_columns_for(word_count)
    case word_count
    when 0..9   then 3
    when 10..16 then 4
    when 17..20 then 5
    when 21..36 then 6
    when 37..42 then 7
    when 43..48 then 8
    when 49..54 then 9
    when 55..60 then 10
    else [12, (word_count / 8.0).ceil].min
    end
  end
end
