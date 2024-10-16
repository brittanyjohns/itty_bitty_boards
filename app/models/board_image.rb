# == Schema Information
#
# Table name: board_images
#
#  id           :bigint           not null, primary key
#  board_id     :bigint           not null
#  image_id     :bigint           not null
#  position     :integer
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  voice        :string
#  next_words   :string           default([]), is an Array
#  bg_color     :string
#  text_color   :string
#  font_size    :integer
#  border_color :string
#  layout       :jsonb
#  status       :string           default("pending")
#  audio_url    :string
#
class BoardImage < ApplicationRecord
  default_scope { order(position: :asc) }
  belongs_to :board
  belongs_to :image
  attr_accessor :skip_create_voice_audio, :skip_initial_layout

  before_create :set_defaults
  after_create :set_next_words
  after_create :save_initial_layout, unless: :skip_initial_layout

  def initialize(*args)
    super
    @skip_create_voice_audio = false
  end

  def set_next_words
    return if next_words.present? || Rails.env.test?
    self.next_words = image.next_words
    save
  end

  def image_prompt
    image.image_prompt
  end

  def clean_up_layout
    new_layout = layout.select { |key, _| ["lg", "md", "sm", "xs", "xxs"].include?(key) }
    update!(layout: new_layout)
  end

  def bg_class
    bg_color ? "bg-#{bg_color}-400" : "bg-white"
  end

  scope :created_today, -> { where("created_at >= ?", Time.zone.now.beginning_of_day) }

  def voice_changed_and_not_existing?
    !image.existing_voices.include?(voice)
  end

  def label
    image.label
  end

  def board_images
    board.board_images.sort_by(&:position)
  end

  def grid_x
    result = nil
    if position
      position_index = position - 1
      result = position_index % board.number_of_columns
    else
      result = 0
    end
    result
  end

  def grid_y
    if position
      result = (position / board.number_of_columns).floor
      result
    else
      0
    end
  end

  def initial_layout
    { "lg" => { "i" => id.to_s, "x" => grid_x, "y" => grid_y, "w" => 1, "h" => 1 },
      "md" => { "i" => id.to_s, "x" => grid_x, "y" => grid_y, "w" => 1, "h" => 1 },
      "sm" => { "i" => id.to_s, "x" => grid_x, "y" => grid_y, "w" => 1, "h" => 1 },
      "xs" => { "i" => id.to_s, "x" => grid_x, "y" => grid_y, "w" => 1, "h" => 1 },
      "xxs" => { "i" => id.to_s, "x" => grid_x, "y" => grid_y, "w" => 1, "h" => 1 } }
  end

  def calucate_position(x, y)
    x + (y * board.number_of_columns) + 1
  end

  def create_voice_audio(voice = nil)
    voice ||= self.voice
    return if @skip_create_voice_audio || Rails.env.test?
    label_voice = "#{image.label_for_filename}_#{voice}"
    filename = "#{label_voice}.aac"
    already_has_audio_file = image.existing_audio_files.include?(filename)
    puts "\nalready_has_audio_file: #{voice}\n" if already_has_audio_file
    self.voice = voice
    audio_file = image.find_audio_for_voice(voice)

    if already_has_audio_file && audio_file
      self.audio_url = image.default_audio_url(audio_file)
    else
      puts "Creating audio file for voice: #{voice}"
      image.find_or_create_audio_file_for_voice(voice)
      audio_file = image.find_audio_for_voice(voice)
      self.audio_url = image.default_audio_url(audio_file)
    end
    @skip_create_voice_audio = true
    save
  end

  def api_view
    {
      id: id,
      image_id: image_id,
      label: label,
      voice: voice,
      bg_color: bg_color,
      text_color: text_color,
      font_size: font_size,
      border_color: border_color,
      layout: layout,
      status: status,
      audio_url: audio_url,
      image_prompt: image_prompt,
      next_words: next_words,
    }
  end

  def description
    image.image_prompt || board.description
  end

  def set_defaults
    audio_file = nil
    if image.use_custom_audio
      self.voice = image.voice
      audio_file = image.find_custom_audio_file
    else
      self.voice = board.voice
      audio_file = image.find_audio_for_voice(voice)
    end

    self.bg_color = image.bg_color
    self.text_color = image.text_color
    self.font_size = image.font_size
    self.border_color = image.border_color
    if audio_file
      self.audio_url = image.default_audio_url(audio_file)
    else
      puts "Board Image - Creating audio file for voice: #{voice} - #{image.label}"
      image.start_create_all_audio_job
      # This probably is nil anyway but just in case
      # self.audio_url = image.audio_url
    end
  end

  def save_defaults
    set_defaults
    save
  end

  def set_position
    self.position = board_images.count + 1
  end

  def get_coordinates_for_screen_size(screen_size)
    layout[screen_size].slice("x", "y")
  end

  def save_initial_layout
    if self.skip_initial_layout == true
      puts "Skipping initial layout"
      return
    end
    if self.layout.blank?
      if image.image_type == "Menu"
        board.rearrange_images
      else
        self.update!(layout: initial_layout)
      end
    end
  end

  def update_layout(layout, screen_size)
    self.layout[screen_size] = layout
    save
  end

  def added_at
    created_at.strftime("%m/%d %I:%M %p")
  end

  def image_last_added_at
    image.docs.last&.created_at&.strftime("%m/%d %I:%M %p")
  end

  def user_docs
    docs = UserDoc.where(user_id: board.user_id, doc_id: image.docs.pluck(:id))
    docs.each do |doc|
      puts "Supposed to update doc: #{doc.id} =>label: #{doc.label}"
    end
  end
end
