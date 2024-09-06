module BoardsHelper
  #   def api_view_with_images(viewing_user = nil)
  #     {
  #       id: id,
  #       name: name,
  #       description: description,
  #       parent_type: parent_type,
  #       parent_id: parent_id,
  #       parent_description: parent_type === "User" ? "User" : parent.description,
  #       parent_prompt: parent_type === "OpenaiPrompt" ? parent.prompt_text : nil,
  #       predefined: predefined,
  #       number_of_columns: number_of_columns,
  #       small_screen_columns: small_screen_columns,
  #       medium_screen_columns: medium_screen_columns,
  #       large_screen_columns: large_screen_columns,
  #       status: status,
  #       token_limit: token_limit,
  #       cost: cost,
  #       audio_url: audio_url,
  #       display_image_url: display_image_url,
  #       floating_words: words,
  #       user_id: user_id,
  #       voice: voice,
  #       created_at: created_at,
  #       updated_at: updated_at,
  #       has_generating_images: has_generating_images?,
  #       current_user_teams: [],
  #       # current_user_teams: viewing_user ? viewing_user.teams.map(&:api_view) : [],
  #       # images: board_images.includes(image: [:docs, :audio_files_attachments, :audio_files_blobs]).map do |board_image|
  #       images: board_images.includes(image: :docs).map do |board_image|
  #         @image = board_image.image
  #         {
  #           id: @image.id,
  #           # id: board_image.id,
  #           mode: board_image.mode,
  #           dynamic_board: board_image.dynamic_board&.api_view,
  #           board_image_id: board_image.id,
  #           label: board_image.label,
  #           image_prompt: board_image.image_prompt,
  #           bg_color: @image.bg_class,
  #           text_color: board_image.text_color,
  #           next_words: board_image.next_words,
  #           position: board_image.position,
  #           src: @image.display_image_url(viewing_user),
  #           audio: board_image.audio_url,
  #           voice: board_image.voice,
  #           layout: board_image.layout,
  #           added_at: board_image.added_at,
  #           image_last_added_at: board_image.image_last_added_at,
  #           part_of_speech: @image.part_of_speech,

  #           status: board_image.status,
  #         }
  #       end,
  #       layout: layout,
  #     }
  #   end

  #   def api_view(viewing_user = nil)
  #     {
  #       id: id,
  #       name: name,
  #       layout: layout,
  #       audio_url: audio_url,
  #       position: position,
  #       description: description,
  #       parent_type: parent_type,
  #       predefined: predefined,
  #       number_of_columns: number_of_columns,
  #       status: status,
  #       token_limit: token_limit,
  #       cost: cost,
  #       display_image_url: display_image_url,
  #       floating_words: words,
  #       user_id: user_id,
  #       voice: voice,
  #     }
  #   end
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
