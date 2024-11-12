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
  attr_accessor :skip_create_voice_audio, :skip_initial_layout, :src

  before_create :set_defaults
  after_create :set_next_words
  before_save :set_label, if: -> { label.blank? }

  # after_initialize :set_initial_layout, if: :layout_invalid?

  def set_initial_layout!
    self.layout = { "lg" => { "i" => id.to_s, "x" => grid_x("lg"), "y" => grid_y("lg"), "w" => 1, "h" => 1 },
                    "md" => { "i" => id.to_s, "x" => grid_x("md"), "y" => grid_y("md"), "w" => 1, "h" => 1 },
                    "sm" => { "i" => id.to_s, "x" => grid_x("sm"), "y" => grid_y("sm"), "w" => 1, "h" => 1 },
                    "xs" => { "i" => id.to_s, "x" => grid_x("sm"), "y" => grid_y("sm"), "w" => 1, "h" => 1 },
                    "xxs" => { "i" => id.to_s, "x" => grid_x("sm"), "y" => grid_y("sm"), "w" => 1, "h" => 1 } }
    self.save
  end

  def set_label
    self.label = image.label
  end

  def layout_invalid?
    return true if layout.blank?
    return true if layout["lg"] == nil || layout["md"] == nil || layout["sm"] == nil || layout["xs"] == nil || layout["xxs"] == nil
    layout["lg"].values.any?(&:nil?) || layout["md"].values.any?(&:nil?) || layout["sm"].values.any?(&:nil?) || layout["xs"].values.any?(&:nil?) || layout["xxs"].values.any?(&:nil?)
  end

  def initialize(*args)
    super
    @skip_create_voice_audio = false
  end

  def set_next_words
    return if next_words.present? || Rails.env.test?
    self.next_words = image.next_words
    save
  end

  def get_predictive_image_for(viewing_user)
    user_id_to_search = viewing_user ? viewing_user.id : nil
    images = Image.with_artifacts.where(user_id: [user_id_to_search, User::DEFAULT_ADMIN_ID], label: label)
    image = images.first
    # image = Image.where(user_id: viewing_user.id, label: label).first
    if image
      return image
    else
      return self.image
    end
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

  def board_images
    board.board_images.sort_by(&:position)
  end

  def grid_x(screen_size = "lg")
    return layout[screen_size]["x"] if layout[screen_size] && layout[screen_size]["x"]
    board.next_available_cell(screen_size)&.fetch("x", 0) || 0
  end

  def grid_y(screen_size = "lg")
    return layout[screen_size]["y"] if layout[screen_size] && layout[screen_size]["y"]
    board.next_available_cell(screen_size)&.fetch("y", 0) || 0
  end

  def initial_layout
    { "lg" => { "i" => id.to_s, "x" => grid_x("lg"), "y" => grid_y("lg"), "w" => 1, "h" => 1 },
      "md" => { "i" => id.to_s, "x" => grid_x("md"), "y" => grid_y("md"), "w" => 1, "h" => 1 },
      "sm" => { "i" => id.to_s, "x" => grid_x("sm"), "y" => grid_y("sm"), "w" => 1, "h" => 1 },
      "xs" => { "i" => id.to_s, "x" => grid_x("sm"), "y" => grid_y("sm"), "w" => 1, "h" => 1 },
      "xxs" => { "i" => id.to_s, "x" => grid_x("sm"), "y" => grid_y("sm"), "w" => 1, "h" => 1 } }
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

  def user
    board.user
  end

  def api_view
    {
      id: id,
      image_id: image_id,
      label: label,
      voice: voice,
      src: image.display_image_url(self.user),
      bg_color: bg_color,
      text_color: text_color,
      font_size: font_size,
      border_color: border_color,
      layout: layout,
      status: status,
      audio_url: audio_url,
      audio: audio_url,
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
      image.start_create_all_audio_job unless Rails.env.test? || Rails.env.development?
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
