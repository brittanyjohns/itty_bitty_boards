# == Schema Information
#
# Table name: board_groups
#
#  id                :bigint           not null, primary key
#  name              :string
#  layout            :jsonb
#  predefined        :boolean          default(FALSE)
#  display_image_url :string
#  position          :integer
#  number_of_columns :integer          default(6)
#  user_id           :integer          not null
#  bg_color          :string
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#
class BoardGroup < ApplicationRecord
  has_many :board_group_boards, dependent: :destroy
  has_many :boards, through: :board_group_boards
  belongs_to :user

  scope :predefined, -> { where(predefined: true) }
  scope :with_artifacts, -> { includes(boards: [:images, :board_images]) }

  validates :name, presence: true

  include PgSearch::Model
  pg_search_scope :search_by_name,
                  against: :name,
                  using: {
                    tsearch: { prefix: true },
                  }

  # after_initialize :set_initial_layout, if: :layout_empty?
  after_save :calculate_grid_layout
  after_save :create_board_audio_files

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

  def api_view_with_boards(viewing_user = nil)
    {
      id: id,
      name: name,
      user_id: user_id,
      predefined: predefined,
      layout: print_grid_layout,
      number_of_columns: number_of_columns,
      display_image_url: display_image_url,
      boards: boards.map { |board| board.api_view(viewing_user) },
      predefined: predefined,
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

  def self.welcome_group
    BoardGroup.find_by(name: "Welcome", predefined: true)
  end

  def self.startup
    BoardGroup.find_or_create_by(name: "Startup", predefined: true)
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
        row.each_with_index do |bi, index|
          new_layout = { i: bi.id, x: index, y: row_count, w: 1, h: 1 }
          bi.update!(layout: new_layout)
          grid_layout << new_layout
        end
        row_count += 1
      end
    end
    grid_layout
  end

  def print_grid_layout
    boards.map(&:layout)
  end

  def adjust_layouts
    layouts = boards.pluck(:layout)
    if layouts.any? { |layout| layout.blank? }
      calculate_grid_layout
    end
  end
end
