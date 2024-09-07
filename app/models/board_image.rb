# == Schema Information
#
# Table name: board_images
#
#  id               :bigint           not null, primary key
#  board_id         :bigint           not null
#  image_id         :bigint           not null
#  position         :integer
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  voice            :string
#  next_words       :string           default([]), is an Array
#  bg_color         :string
#  text_color       :string
#  font_size        :integer
#  border_color     :string
#  layout           :jsonb
#  status           :string           default("pending")
#  audio_url        :string
#  mode             :string           default("static"), not null
#  dynamic_board_id :integer
#
class BoardImage < ApplicationRecord
  default_scope { order(position: :asc) }
  belongs_to :board
  belongs_to :image
  belongs_to :dynamic_board, optional: true
  attr_accessor :skip_create_voice_audio, :skip_initial_layout

  before_create :set_defaults
  after_create :set_next_words
  after_create :save_initial_layout, unless: :skip_initial_layout

  def initialize(*args)
    super
    @skip_create_voice_audio = false
  end

  def set_next_words
    puts "\n\n>>>>> Setting next words\n"
    return if next_words.present? || Rails.env.test?
    if image.next_words.blank?
      puts "No next words"
      image.set_next_words!
      image.reload
    end
    self.next_words = image.next_words
    save
    self.next_words
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
    audio_file = image.find_audio_for_voice(voice)

    if already_has_audio_file
      self.audio_url = audio_file.url
    else
      puts "Creating audio file for voice: #{voice}"
      image.find_or_create_audio_file_for_voice(voice)
      self.audio_url = image.find_audio_for_voice(voice)&.url
    end
    self.voice = voice
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
      src: image.display_image_url,
      image_prompt: image_prompt,
      next_words: next_words,
      # dynamic_board: dynamic_board&.api_view_with_images,
      added_at: added_at,
      board_mode: board.mode,
      dynamic_board_mode: dynamic_board&.mode,
      test_mode: dynamic_board_id ? "dynamic" : "static",
      mode: mode,
    }
  end

  def description
    "#{label} - #{voice}"
  end

  def make_dynamic(dynamic_user_id = nil)
    puts "Making dynamic - dynamic_user_id: #{dynamic_user_id}"
    if next_words.blank?
      puts "No next words"
      next_words = set_next_words
    end
    if image.user_id && image.user_id != dynamic_user_id
      admin_user = User.admins.find_by(id: dynamic_user_id)
      if admin_user
        puts "Admin user found"
        dynamic_user_id = admin_user.id
      else
        puts "User id mismatch - image.user_id: #{image.user_id} - dynamic_user_id: #{dynamic_user_id}"
        return
      end
    end

    core_image = image
    dynamic_board = DynamicBoard.create(name: label, board: board)

    unless dynamic_board
      puts "Failed to create dynamic board"
      return
    end

    update!(mode: "dynamic", dynamic_board_id: dynamic_board.id)

    user = board.user
    next_words_to_set = next_words || image.next_words || []
    # next_words_to_set next_words_to_set<< label
    puts "Next words to set: #{next_words_to_set}"
    puts "image.next_words: #{image.next_words}"
    puts "next_words: #{next_words}"

    next_words_to_set.each do |word|
      word = word.downcase
      img = user.images.find_by(label: word)

      img = Image.public_img.find_or_create_by(label: word) unless img

      dynamic_board.add_image(img.id)
      puts "Added image: #{img.label} to dynamic board #{dynamic_board.name}"
    end
    dynamic_board.reset_layouts
    dynamic_board.save
  end

  def make_static
    return unless mode == "dynamic"
    if dynamic_board
      dynamic_board.destroy
    else
      puts "No dynamic board found"
    end

    update!(mode: "static")
  end

  def set_defaults
    self.voice = board.voice
    self.bg_color = image.bg_color
    self.text_color = image.text_color
    self.font_size = image.font_size
    self.border_color = image.border_color
    self.audio_url = image.audio_url
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
    puts "\n\n*** save_initial_layout ***\n\nself.skip_initial_layout: #{self.skip_initial_layout}"
    if self.skip_initial_layout == true
      puts "Skipping initial layout"
      return
    else
      puts "\n\nSaving initial layout\n\n"
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
