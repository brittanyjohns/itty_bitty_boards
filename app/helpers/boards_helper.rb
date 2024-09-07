module BoardsHelper
  SCREEN_SIZES = %w[sm md lg].freeze

  def print_grid_layout_for_screen_size(screen_size)
    layout_to_set = layout[screen_size] || {}
    board_images.order(:position).each_with_index do |bi, i|
      if bi.layout[screen_size]
        layout_to_set[bi.id] = bi.layout[screen_size]
      end
    end
    layout_to_set = layout_to_set.compact # Remove nil values
    layout_to_set
  end

  def print_grid_layout
    layout_to_set = layout || {}
    SCREEN_SIZES.each do |screen_size|
      layout_to_set[screen_size] = print_grid_layout_for_screen_size(screen_size)
    end
    layout_to_set
  end

  def calculate_grid_layout_for_screen_size(screen_size, reset_layouts = false)
    case screen_size
    when "sm"
      number_of_columns = self.small_screen_columns || 1
    when "md"
      number_of_columns = self.medium_screen_columns || 8
    when "lg"
      number_of_columns = self.large_screen_columns || 12
    else
      number_of_columns = self.large_screen_columns || 12
    end

    layout_to_set = {} # Initialize as a hash

    position_all_board_images
    row_count = 0
    bi_count = board_images.count
    rows = (bi_count / number_of_columns.to_f).ceil
    ActiveRecord::Base.logger.silence do
      board_images.order(:position).each_slice(number_of_columns) do |row|
        row.each_with_index do |bi, index|
          new_layout = {}
          if bi.layout[screen_size] && reset_layouts == false
            new_layout = bi.layout[screen_size]
          else
            new_layout = { "i" => bi.id.to_s, "x" => index, "y" => row_count, "w" => 1, "h" => 1 }
          end

          bi.layout[screen_size] = new_layout
          bi.skip_create_voice_audio = true
          bi.save
          bi.clean_up_layout
          layout_to_set[bi.id] = new_layout # Treat as a hash
        end
        row_count += 1
      end
    end
    Rails.logger.debug "calculate_grid_layout_for_screen_size: #{layout_to_set}"

    self.layout[screen_size] = layout_to_set.values # Convert back to an array if needed
    self.board_images.reset
    self.save!
  end

  def set_layouts_for_screen_sizes
    calculate_grid_layout_for_screen_size("sm", true)
    calculate_grid_layout_for_screen_size("md", true)
    calculate_grid_layout_for_screen_size("lg", true)
  end

  def reset_layouts
    self.layout = {}
    self.set_layouts_for_screen_sizes
    self.save!
  end

  def position_all_board_images
    ActiveRecord::Base.logger.silence do
      board_images.order(:position).each_with_index do |bi, index|
        unless bi.position && bi.position == index
          bi.update!(position: index)
        end
      end
    end
  end
end
