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
  has_many :boards
  has_many :board_images, through: :boards
  has_many :images, through: :board_images
  belongs_to :user
  belongs_to :root_board, class_name: "Board", optional: true

  scope :predefined, -> { where(predefined: true) }
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

  after_initialize :set_initial_layout, if: :layout_empty?
  after_save :calculate_grid_layout
  # after_save :create_board_audio_files
  before_save :set_root_board
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
    self.layout = calculate_grid_layout
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
      # layout: print_grid_layout,
      # number_of_columns: number_of_columns,
      display_image_url: display_image_url,
      created_at: created_at.strftime("%Y-%m-%d %H:%M:%S"),
    }
  end

  def api_view_with_boards(viewing_user = nil)
    {
      id: id,
      name: name,
      user_id: user_id,
      predefined: predefined,
      layout: print_grid_layout,
      number_of_columns: number_of_columns,
      display_image_url: display_image_url,
      slug: slug,
      public_url: public_url,
      featured: featured,
      created_at: created_at.strftime("%Y-%m-%d %H:%M:%S"),
      boards: boards.map do |board|
        { id: board.id,
          name: board.name,
          board_type: board.board_type,
          description: board.description,
          user_id: board.user_id,
          parent_id: board.parent_id,
          parent_type: board.parent_type,
          group_layout: board.group_layout,
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
      boards.order(:position).each_with_index do |bi, index|
        unless bi.position && bi.position == index
          bi.update!(position: index)
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

  def calculate_grid_layout
    position_all_boards
    grid_layout = []
    row_count = 0
    boards_count = boards.count
    number_of_columns = self.number_of_columns || 6
    rows = (boards_count / number_of_columns.to_f).ceil
    ActiveRecord::Base.logger.silence do
      boards.order(:position).each_slice(number_of_columns) do |row|
        row.each_with_index do |board, index|
          new_layout = { i: board.id, x: index, y: row_count, w: 1, h: 1 }
          board.update(group_layout: new_layout)
          grid_layout << new_layout
        end
        row_count += 1
      end
    end
    grid_layout
  end

  def print_grid_layout
    grid = boards.map(&:group_layout)
    grid.compact  # remove nils
  end

  def adjust_layouts
    layouts = boards.pluck(:group_layout)
    if layouts.any? { |layout| layout.blank? }
      calculate_grid_layout
    end
  end
end
