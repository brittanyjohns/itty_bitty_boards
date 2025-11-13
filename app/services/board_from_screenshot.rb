# app/services/board_from_screenshot.rb
class BoardFromScreenshot
  attr_reader :import, :user, :screen_size

  def self.commit!(import, screen_size: "lg")
    new(import, screen_size: screen_size).commit!
  end

  def initialize(import, screen_size: "lg")
    @import = import
    @user = import.user
    @screen_size = screen_size
  end

  def commit!
    raise "Import not ready (status=#{import.status})" unless import.status == "needs_review"

    ActiveRecord::Base.transaction do
      board = build_or_update_board!
      add_cells_to_board!(board)
      finalize_import!(board)
      board
    end
  rescue => e
    import.update!(status: "failed", error_message: e.message) rescue nil
    Rails.logger.error "[BoardFromScreenshot] Error: #{e.class}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise
  end

  private

  def build_or_update_board!
    if import.respond_to?(:board) && import.board.present?
      board = import.board
      cols = (import.guessed_cols || board.large_screen_columns || 6).to_i
      board.large_screen_columns = cols
      board.medium_screen_columns = cols
      board.small_screen_columns = [cols, 4].min
      board.number_of_columns = cols
      board.save!
      return board
    end

    cols = (import.guessed_cols || 6).to_i
    cols = 1 if cols < 1

    name = import.try(:name).presence || "Imported Board from Screenshot ##{import.id}"

    board = Board.new(
      name: name,
      user_id: user.id,
      board_type: "static",
      large_screen_columns: cols,
      medium_screen_columns: cols,
      small_screen_columns: [cols, 4].min,
      number_of_columns: cols,
      data: (import.metadata || {}).merge("source_type" => "ScreenshotImport",
                                          "board_screenshot_import_id" => import.id),
    )

    board.generate_unique_slug
    board.assign_parent
    board.save!
    board
  end

  def add_cells_to_board!(board)
    # Clear any previous auto-generated images if you want a fresh commit
    if import.respond_to?(:board_screenshot_cells)
      board.board_images.destroy_all
      board.reload
    end

    candidates = import.board_screenshot_cells
      .order(:row, :col)
      .to_a

    position_counter = 0

    candidates.each do |c|
      row = c.row.to_i
      col = c.col.to_i
      next if row < 0 || col < 0

      label = (c.respond_to?(:label_norm) && c.label_norm.presence) ||
              (c.respond_to?(:label_raw) && c.label_raw.presence)

      next if label.blank?
      bg_color = c.respond_to?(:bg_color) ? c.bg_color : "white"
      Rails.logger.info "[BoardFromScreenshot] Adding cell at (#{row}, #{col}): '#{label}' with bg_color='#{bg_color}'"

      normalized_label = label.to_s.strip.downcase

      image = find_or_create_image_for_label!(normalized_label)

      board_image = board.board_images.build(
        image: image,
        position: position_counter,
        label: normalized_label,
        display_label: label,
        language: board.language,
        bg_color: bg_color,
      )
      # avoid any "initial layout" auto-logic from kicking in later
      board_image.skip_initial_layout = true
      board_image.save!

      # Now that we have an ID, set explicit grid layout using row/col
      layout_lg = {
        "i" => board_image.id.to_s,
        "x" => col,  # IMPORTANT: col -> x
        "y" => row,  # IMPORTANT: row -> y
        "w" => 1,
        "h" => 1,
      }

      board_image.layout ||= {}
      board_image.layout["lg"] = layout_lg
      board_image.layout["md"] = layout_lg.dup
      board_image.layout["sm"] = layout_lg.dup
      board_image.layout["xs"] = layout_lg.dup
      board_image.layout["xxs"] = layout_lg.dup
      board_image.save!

      position_counter += 1
    end
  end

  def find_or_create_image_for_label!(normalized_label)
    # Try user image first
    image = user.images.find_by("LOWER(label) = ?", normalized_label)

    # Then public/admin images
    image ||= Image.public_img.find_by("LOWER(label) = ?", normalized_label)

    # Fallback: create new
    image ||= Image.new(label: normalized_label, user_id: user.id)
    image.skip_categorize = true
    unless image.persisted?
      image.save!
    end

    image
  end

  def finalize_import!(board)
    attrs = { status: "completed" }
    attrs[:board_id] = board.id if import.respond_to?(:board_id)
    attrs[:board] = board if import.respond_to?(:board=)

    import.update!(attrs)
    board
  end
end
