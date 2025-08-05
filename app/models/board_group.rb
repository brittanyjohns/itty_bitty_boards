# == Schema Information
#
# Table name: board_groups
#
#  id                   :bigint           not null, primary key
#  name                 :string
#  layout               :jsonb
#  predefined           :boolean          default(FALSE)
#  display_image_url    :string
#  position             :integer
#  number_of_columns    :integer          default(6)
#  user_id              :integer          not null
#  bg_color             :string
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  root_board_id        :integer
#  original_obf_root_id :string
#
class BoardGroup < ApplicationRecord
  # has_many :board_group_boards, dependent: :destroy
  has_many :board_group_boards, dependent: :destroy
  has_many :boards, through: :board_group_boards
  has_many :board_images, through: :boards
  has_many :images, through: :board_images
  belongs_to :user
  belongs_to :root_board, class_name: "Board", optional: true

  scope :predefined, -> { where(predefined: true) }
  scope :alphabetical, -> { order(Arel.sql("LOWER(name) ASC")) }
  scope :featured, -> { where(predefined: true, featured: true) }
  scope :by_name, ->(name) { where("name ILIKE ?", "%#{name}%") }
  scope :by_user, ->(user_id) { where(user_id: user_id) }
  scope :recent, -> { order(created_at: :desc) }
  scope :with_boards, -> { includes(:boards) }

  scope :with_artifacts, -> { includes(boards: [:images, :board_images]) }

  validates :name, presence: true

  include BoardsHelper

  include PgSearch::Model
  pg_search_scope :search_by_name,
                  against: :name,
                  using: {
                    tsearch: { prefix: true },
                  }

  before_create :set_slug

  # after_initialize :set_initial_layout, if: :layout_empty?
  # after_save :set_layouts_for_screen_sizes
  # after_save :create_board_audio_files
  before_create :set_root_board
  after_initialize :set_number_of_columns, if: :no_colmns_set

  def set_number_of_columns
    self.number_of_columns = 6
  end

  def update_all_board_images
    images.includes(:board_images).find_each do |image|
      image.update_all_boards_image_belongs_to(image.src_url) if image.src_url.present?
    end
  end

  def update_all_boards
    boards.includes(:images).find_each do |board|
      first_img_url = board.images.select { |img| img.src_url.present? }.first&.src_url
      board.display_image_url = first_img_url if first_img_url.present? && board.display_image_url.blank?
      board.save
    end
  end

  def add_board(board)
    if boards.include?(board)
      board_group_board = board_group_boards.find_by(board: board)
      Rails.logger.info "Board #{board.id} already in group #{id}"
      return board_group_board
    end
    begin
      bgb = board_group_boards.create(board: board)
      # bgb.set_initial_layout! if bgb.layout_invalid?
      bgb.save!
      bgb.set_initial_layout! if bgb.layout_invalid?
      bgb.clean_up_layout
      bgb
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.error "Failed to add board #{board.id} to group #{id}: #{e.message}"
      nil
    rescue StandardError => e
      Rails.logger.error "Unexpected error while adding board #{board.id} to group #{id}: #{e.message}"
      nil
    end
  end

  def update_grid_layout(layout_to_set, screen_size)
    layout_for_screen_size = self.layout[screen_size] || []
    Rails.logger.debug "Updating grid layout for screen size: #{screen_size} with layout: #{layout_to_set.inspect}"
    unless layout_to_set.is_a?(Array)
      Rails.logger.error "Invalid layout format for screen size #{screen_size}: #{layout_to_set.inspect}"
      return
    end
    layout_to_set.each_with_index do |layout_item, i|
      id_key = layout_item[:i]
      layout_hash = layout_item.with_indifferent_access
      id_key = layout_hash[:i] || layout_hash["i"]
      Rails.logger.debug "Processing layout item with ID: #{id_key} for screen size: #{screen_size}"
      bgb = board_group_boards.find(id_key) rescue nil
      bgb = board_group_boards.find_by(board_id: id_key) if bgb.nil?

      if bgb.nil?
        next
      end
      bgb.group_layout[screen_size] = layout_hash
      Rails.logger.debug "Setting layout for board group board ID: #{bgb.id} to #{layout_hash.inspect}"

      bgb.position = i
      # bgb.clean_up_layout
      bgb.save!
    end
    self.layout[screen_size] = layout_to_set
    self.board_group_boards.reset
    self.save!
  end

  def no_colmns_set
    number_of_columns.nil?
  end

  def create_board_audio_files
    boards.each do |board|
      puts "Creating audio files for board #{board.id}"
      next if board.audio_url.present?
      board.create_voice_audio
    end
  end

  def layout_empty?
    layout.blank?
  end

  def set_initial_layout
    calculate_grid_layout_for_screen_size("lg")
  end

  def public_url
    base_url = ENV["FRONT_END_URL"] || "http://localhost:8100"
    "#{base_url}/board-sets/#{slug}"
  end

  def api_view(viewing_user = nil)
    {
      id: id,
      name: name,
      user_id: user_id,
      slug: slug,
      public_url: public_url,
      featured: featured,
      predefined: predefined,
      root_board_id: root_board_id,
      original_obf_root_id: original_obf_root_id,
      small_screen_columns: small_screen_columns,
      medium_screen_columns: medium_screen_columns,
      large_screen_columns: large_screen_columns,
      layout: print_grid_layout,
      saved_layout: layout,
      number_of_columns: number_of_columns,
      display_image_url: display_image_url,
      created_at: created_at.strftime("%Y-%m-%d %H:%M:%S"),
    }
  end

  def api_view_with_boards(viewing_user = nil)
    cached_board_group_boards = board_group_boards.includes(:board)
    {
      id: id,
      name: name,
      user_id: user_id,
      predefined: predefined,
      layout: print_grid_layout,
      saved_layout: layout,
      number_of_columns: number_of_columns,
      display_image_url: display_image_url,
      small_screen_columns: small_screen_columns,
      medium_screen_columns: medium_screen_columns,
      large_screen_columns: large_screen_columns,
      slug: slug,
      public_url: public_url,
      featured: featured,
      created_at: created_at.strftime("%Y-%m-%d %H:%M:%S"),
      boards: cached_board_group_boards.map do |board_group_board|
        board = board_group_board.board
        { id: board_group_board.id,
          board_id: board.id,
          name: board.name,
          board_type: board.board_type,
          description: board.description,
          user_id: board.user_id,
          parent_id: board.parent_id,
          parent_type: board.parent_type,
          group_layout: board_group_board.group_layout,
          position: board_group_board.position,
          layout: board_group_board.group_layout,
          layout_invalid: board_group_board.layout_invalid?,
          display_image_url: board.display_image_url,
          audio_url: board.audio_url }
      end,
    }
  end

  def user_api_view
    {
      id: id,
      name: name,

    }
  end

  def position_all_boards
    ActiveRecord::Base.logger.silence do
      board_group_boards.order(:position).each_with_index do |bgb, index|
        unless bgb.position && bgb.position == index
          bgb.update!(position: index)
        end
      end
    end
  end

  # def add_board(board)
  #   if boards.include?(board)
  #     Rails.logger.info "Board #{board.id} already in group #{id}"
  #     return
  #   end
  #   board_group_boards.create(board: board)
  # end

  def self.welcome_group
    BoardGroup.find_by(name: "Welcome", predefined: true)
  end

  def set_root_board
    og_root_board_id = original_obf_root_id
    if og_root_board_id.present?
      self.root_board = Board.find_by(obf_id: og_root_board_id)
    else
      root_board = boards.first
      og_root_board_id = root_board&.obf_id
      self.original_obf_root_id = og_root_board_id
      self.root_board_id = root_board&.id
    end
  end

  def self.startup
    puts "Creating startup group - @startup is #{@startup&.id}"
    @startup ||= BoardGroup.find_or_create_by(name: "Startup", predefined: true)
  end

  def calculate_grid_layout_for_screen_size(screen_size, reset_layouts = false)
    num_of_columns = get_number_of_columns(screen_size)
    layout_to_set = [] # Initialize as an array

    # position_all_board_group_boards
    row_count = 0
    board_group_boards_count = board_group_boards.count
    rows = (board_group_boards_count / num_of_columns.to_f).ceil
    ActiveRecord::Base.logger.silence do
      board_group_boards.order(:position).each_slice(num_of_columns) do |row|
        row.each_with_index do |bgb, index|
          new_layout = {}
          if bgb.group_layout[screen_size] && reset_layouts == false
            Rails.logger.debug "Using existing layout for board group board #{bgb.id} on screen size #{screen_size}"
            new_layout = bgb.group_layout[screen_size]
          else
            Rails.logger.debug "Setting initial layout for board group board #{bgb.id} on screen size #{screen_size}"
            width = bgb.group_layout[screen_size] ? bgb.group_layout[screen_size]["w"] : 1
            height = bgb.group_layout[screen_size] ? bgb.group_layout[screen_size]["h"] : 1
            Rails.logger.debug "Width: #{width}, Height: #{height} for board group board #{bgb.id} on screen size #{screen_size}"
            new_layout = { "i" => bgb.id.to_s, "x" => index, "y" => row_count, "w" => width, "h" => height }
          end

          bgb.group_layout[screen_size] = new_layout
          bgb.save!
          bgb.clean_up_layout
          layout_to_set << new_layout
        end
        row_count += 1
      end
    end
    layout = {}

    layout[screen_size] = layout_to_set
    self.layout = layout
    self.board_group_boards.reset
    self.save!
  end

  def set_layouts_for_screen_sizes
    calculate_grid_layout_for_screen_size("sm", true)
    calculate_grid_layout_for_screen_size("md", true)
    calculate_grid_layout_for_screen_size("lg", true)
  end

  # def print_grid_layout
  #   layout_to_set = {}
  #   Board::SCREEN_SIZES.each do |screen_size|
  #     puts "Setting layout for screen size: #{screen_size}"

  #     layout_to_set[screen_size] = print_grid_layout_for_screen_size(screen_size)
  #   end
  #   layout_to_set
  # end

  def print_grid_layout_for_screen_size(screen_size)
    layout_to_set = {}
    Rails.logger.debug "Printing grid layout for screen size: #{screen_size}"
    board_group_boards.order(:position).each_with_index do |bgb, i|
      if bgb.group_layout[screen_size]
        layout_to_set[bgb.id] = bgb.group_layout[screen_size]
      end
    end
    layout_to_set = layout_to_set.compact # Remove nil values
    Rails.logger.debug "Layout for screen size #{screen_size}: #{layout_to_set.inspect}"
    layout_to_set
  end

  def print_grid_layout
    layout_to_set = layout || {}
    Board::SCREEN_SIZES.each do |screen_size|
      layout_to_set[screen_size] = print_grid_layout_for_screen_size(screen_size)
    end
    layout_to_set
  end

  def update_board_layout(screen_size)
    self.layout = {}
    self.layout[screen_size] = {}
    board_group_boards.order(:position).each do |bgb|
      bgb.group_layout[screen_size] = bgb.group_layout[screen_size] || { x: 0, y: 0, w: 1, h: 1 } # Set default layout
      bgb_layout = bgb.group_layout[screen_size].merge("i" => bgb.id.to_s)
      self.layout[screen_size][bgb.id] = bgb_layout
    end
    self.save
    self.board_group_boards.reset
  end

  def adjust_layouts
    layouts = board_group_boards.pluck(:group_layout)
    if layouts.any? { |layout| layout.blank? }
      calculate_grid_layout
    end
  end
end
