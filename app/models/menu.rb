# == Schema Information
#
# Table name: menus
#
#  id          :bigint           not null, primary key
#  user_id     :bigint           not null
#  name        :string
#  description :text
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  token_limit :integer          default(0)
#  predefined  :boolean          default(FALSE)
#  raw         :text
#  item_list   :string           default([]), is an Array
#  prompt_sent :text
#  prompt_used :text
#
class Menu < ApplicationRecord
  belongs_to :user
  has_many :boards, as: :parent, dependent: :destroy
  has_many :docs, as: :documentable, dependent: :destroy
  has_many :board_images, through: :boards
  has_many :images, through: :board_images
  has_one_attached :menu_image

  # PROMPT_ADDITION = " The dish should be presented looking fresh and appetizing on a simple, uncluttered background.
  #  The lighting should be natural and warm, enhancing the appeal of the food and creating a welcoming atmosphere.
  #   Ensure the image looks realistic, like an actual photograph from a family restaurant's menu."
  PROMPT_ADDITION = "This image should look like a professional photograph from a restaurant menu, with vibrant colors and appealing presentation."
  include ImageHelper

  validates :name, presence: true

  accepts_nested_attributes_for :docs

  # scope :predefined, -> { where(predefined: true) }
  scope :user_defined, -> { where(predefined: false) }

  def self.predefined
    joins(:boards).where(boards: { predefined: true, user_id: User::DEFAULT_ADMIN_ID }).distinct
  end

  def self.public_menus
    joins(:boards).where(boards: { predefined: true, user_id: User::DEFAULT_ADMIN_ID, favorite: true }).distinct
  end

  def self.user_menus(user_id)
    where(user_id: user_id)
  end

  def self.predefined_menus
    where(predefined: true)
  end

  def self.user_defined_menus
    where(predefined: false)
  end

  def self.default_menu
    predefined.first || new(name: "Default Menu")
  end

  def main_board
    doc_boards.first || boards.first
  end

  def label
    name
  end

  def self.set_image_types
    all.each do |menu|
      menu.images.map { |i| i.update(image_type: "Menu") }
    end
  end

  def doc_boards
    docs.map(&:board).compact
  end

  def resource_type
    "Menu"
  end

  def menu_image_url
    return if !menu_image.attached?
    if ENV["ACTIVE_STORAGE_SERVICE"] == "amazon" || Rails.env.production?
      cdn_host = ENV["CDN_HOST"]
      if cdn_host
        "#{cdn_host}/#{menu_image.key}" # Construct CloudFront URL
      else
        menu_image.url # Fallback to the direct Active Storage URL
      end
    else
      menu_image.url
    end
  end

  def create_board_from_menu_image(new_doc, board_id = nil)
    unless new_doc
      puts "NO NEW DOC FOUND"
      return nil
    end
    unless new_doc.processed
      puts "NO PROCESSED DESCRIPTION FOUND"
      return nil
    end
    begin
      board = board_id ? Board.find(board_id) : self.boards.new
      board.user = self.user
      board.name = self.name || "Board for Doc #{id}"
      board.token_limit = token_limit
      board.description = new_doc.processed
      board.number_of_columns = 6
      board.save!
      new_doc.update!(board_id: board.id)
      create_images_from_description(board)
      board.reset_layouts
      board
    rescue => e
      Rails.logger.error "**** ERROR **** \n#{e.message}\n#{e.backtrace}\n"
      nil
    end
  end

  def rerun_image_description_job
    @user = self.user
    board = self.boards.last
    tokens_used = 0
    total_cost = board.cost || 0

    minutes_to_wait = 0
    images_generated = 0
    board_images.each_slice(8) do |board_image_slice|
      board_image_slice.each do |board_image|
        image = board_image.image
        if should_generate_image(image, self.user, tokens_used, total_cost, true)
          board_image.update!(status: "generating")
          img_prompt = image.image_prompt.present? ? image.image_prompt : nil
          Rails.logger.debug "Rerunning image generation for #{image.label} with prompt: #{img_prompt}"
          image.start_generate_image_job(minutes_to_wait, self.user_id, img_prompt, board.id)
          tokens_used += 1
          total_cost += 1
          images_generated += 1
        else
          puts "Not generating image for #{image.label}"
          board_image.update!(status: "skipped")
        end
      end
      minutes_to_wait += 1
    end
    #  Disabling token usage for now

    # @user.remove_tokens(tokens_used)
    # puts "USED #{tokens_used} tokens for #{images_generated} images"
    # board.add_to_cost(tokens_used) if board
  end

  def public_url
    board_id = main_board&.id || boards.first&.id
    base_url = ENV["FRONT_END_URL"] || "http://localhost:8100"
    "#{base_url}/pm/#{board_id}?returnUrl=#{base_url}/mymenu"
  end

  def create_images_from_description(board)
    Rails.logger.debug "Creating images from description for Menu #{id} - #{name}"
    json_description = JSON.parse(description)
    images = []
    new_board_images = []
    tokens_used = 0
    menu_item_list = []

    if json_description && json_description["menu_items"].blank?
      Rails.logger.error "No menu items found in description for Menu #{id}"
      return nil
    end
    json_description["menu_items"].each do |food|
      if food["name"].blank? || food["image_description"].blank?
        Rails.logger.info "Blank name or image description for #{food.inspect}"
        next
      end
      if food["image_description"]&.downcase&.include?("unknown")
        Rails.logger.info "Skipping image generation for unknown item: #{food["name"]}"
        next
      end
      item_name = menu_item_name(food["name"])
      menu_item_list << item_name
      # image = Image.find_by(label: item_name, user_id: self.user_id)
      # image = Image.find_by(label: item_name, private: false) unless image
      # image = Image.find_by(label: item_name, private: nil) unless image
      # new_image = Image.create(label: item_name, image_type: self.class.name) unless image
      # image = new_image if new_image

      # unless food["image_description"].blank? || food["image_description"] == item_name
      #   image.image_prompt = food["image_description"]
      #   image.image_prompt += " #{food["description"]}" if food["description"]
      # else
      #   image.image_prompt = "Create a high-resolution image of #{item_name}"
      #   image.image_prompt += " with #{food["description"]}" if food["description"]
      # end
      # image.private = false
      # image.image_type = "Menu"
      # image.display_description = image.image_prompt
      # image.save!
      # image.image_prompt += PROMPT_ADDITION
      # new_board_image = board.add_image(image.id)
      # new_board_image&.save_initial_layout if new_board_image
      # images << image
      # new_board_images << new_board_image if new_board_image
    end

    # total_cost = board.cost || 0
    # minutes_to_wait = 0
    # images_generated = 0
    begin
      self.update(item_list: menu_item_list)
      words = json_description["menu_items"].map { |food| food["name"] }.compact
      Rails.logger.debug "Extracted words for image generation: #{words.inspect}"
      board.update_column(:status, "finding_images")
      board.find_or_create_images_from_word_list(words)
      board.update_column(:status, "complete")
    rescue => e
      Rails.logger.error "**** ERROR **** \n#{e.message}\n#{e.backtrace}\n"
      # board.update(status: "error") if board
      board.update(status: "error - #{e.message}\n#{e.backtrace}\n") if board
    end
  end

  def api_view(viewing_user = nil)
    {
      id: id,
      name: name,
      description: description,
      prompt_sent: prompt_sent,
      prompt_used: prompt_used,
      raw: raw,
      token_limit: token_limit,
      board: { name: main_board&.name, id: main_board&.id },
      displayImage: docs.last&.tile_url,
      can_edit: viewing_user.admin? || viewing_user.id == user_id,
      user_id: user_id,
      status: main_board&.status || "error",
      created_at: created_at,
      updated_at: updated_at,
      has_generating_images: main_board&.has_generating_images?,
      predefined: predefined,
      public_url: public_url,
    }
  end

  def has_generating_images?
    main_board&.has_generating_images?
  end

  def pending_images
    main_board&.pending_images
  end

  def menu_item_name(item_name)
    item_name.downcase!
    # Strip out any non-alphanumeric characters
    item_name.gsub(/[^a-z ]/i, "")
    item_name
  end

  def run_image_description_job(board_id = nil, screen_size = nil)
    EnhanceImageDescriptionJob.perform_async(self.id, board_id, screen_size)
  end

  # Primary extraction path for a menu board: send the uploaded menu image
  # straight to a vision model, persist the structured result, and build the
  # board from it. Returns the parsed result hash, or nil on failure (the
  # caller job maps nil to a board "error" status).
  def enhance_image_description(board_id = nil)
    board = Board.find_by(id: board_id) if board_id
    unless board
      Rails.logger.error "enhance_image_description> No board found for this menu."
      return nil
    end

    image_url = menu_image_for_vision(board)
    unless image_url
      Rails.logger.error "enhance_image_description> No menu image attached for Menu #{id} - #{name}"
      return nil
    end

    begin
      result = MenuVisionService.new.extract_menu_items(image_url: image_url)
      if result.blank? || result["menu_items"].blank?
        Rails.logger.error "enhance_image_description> No menu items extracted for Menu #{id} - #{name}"
        return nil
      end

      json = result.to_json
      new_doc = docs.last
      if new_doc
        new_doc.processed = json
        new_doc.current = true
        new_doc.user_id = user_id
        new_doc.save!
      end

      update!(description: json, prompt_sent: json, prompt_used: json)

      create_board_from_menu_image(new_doc, board_id)
      result
    rescue => e
      Rails.logger.error "**** ERROR **** \n#{e.message}\n#{e.backtrace}\n"
      nil
    end
  end

  # Resolve a publicly reachable URL for the uploaded menu image. The same
  # file is attached to both menu_image and the board's preview_image; prefer
  # menu_image_url since it is CDN-aware.
  def menu_image_for_vision(board)
    return menu_image_url if menu_image.attached?
    board.preview_image.url if board&.preview_image&.attached?
  end

  def open_ai_opts
    { prompt: prompt_to_send }
  end

  def prompt_to_send
    name.blank? ? "Create a menu" : "Create a menu for #{name}"
  end

  def prompt_for_label
    "Create a high-resolution image of"
  end
end
