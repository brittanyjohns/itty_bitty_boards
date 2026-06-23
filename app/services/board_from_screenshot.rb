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
    raise "Import not ready (status=#{import.status})" if import.status == "failed"

    ActiveRecord::Base.transaction do
      board = build_board!
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

  def build_board!
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
      board_screenshot_import_id: import.id,
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
    # build_board! always creates a fresh Board, so there are no prior images to
    # clear — the old destroy_all/reload was dead work on every commit.
    candidates = import.board_screenshot_cells
      .order(:row, :col)
      .to_a

    # Resolve each distinct label once and reuse — a board often repeats labels,
    # and image resolution is the expensive part of the loop.
    image_cache = {}
    position_counter = 0

    candidates.each do |c|
      row = c.row.to_i
      col = c.col.to_i
      next if row < 0 || col < 0

      label = (c.respond_to?(:label_norm) && c.label_norm.presence) ||
              (c.respond_to?(:label_raw) && c.label_raw.presence)

      next if label.blank?
      bg_color = c.respond_to?(:bg_color) ? c.bg_color : "white"

      normalized_label = label.to_s.strip.downcase

      image = (image_cache[normalized_label] ||= find_or_create_image_for_label!(normalized_label))

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

      # Now that we have an ID, set explicit grid layout using row/col.
      # update_columns writes layout only — re-running save!/before_save here
      # would re-derive the tile label from the image and rename it.
      layout_lg = {
        "i" => board_image.id.to_s,
        "x" => col,  # IMPORTANT: col -> x
        "y" => row,  # IMPORTANT: row -> y
        "w" => 1,
        "h" => 1,
      }
      layout = { "lg" => layout_lg, "md" => layout_lg.dup, "sm" => layout_lg.dup,
                 "xs" => layout_lg.dup, "xxs" => layout_lg.dup }
      board_image.update_columns(layout: layout)

      position_counter += 1
    end
  end

  # Prefer a curated, art-bearing image so imported tiles aren't blank, falling
  # back to reusing an existing blank image, then creating one (skip_categorize
  # so commit never triggers an OpenAI categorization call).
  def find_or_create_image_for_label!(normalized_label)
    arted = Boards::ImageResolver.best_arted_for(normalized_label, user)
    return arted if arted

    existing = user.images.where("LOWER(label) = LOWER(?)", normalized_label).first ||
               Image.public_img.where("LOWER(label) = LOWER(?)", normalized_label).first
    return existing if existing

    image = Image.new(label: normalized_label, user_id: user.id)
    image.skip_categorize = true
    image.save!
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
