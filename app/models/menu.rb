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

  PROMPT_ADDITION = " The dish should be presented looking fresh and appetizing on a simple, uncluttered background.
   The lighting should be natural and warm, enhancing the appeal of the food and creating a welcoming atmosphere.
    Ensure the image looks realistic, like an actual photograph from a family restaurant's menu."
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
    doc_boards.first
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

  def create_board_from_image(new_doc, board_id = nil)
    unless new_doc
      puts "NO NEW DOC FOUND"
      return nil
    end
    unless new_doc.processed
      puts "NO PROCESSED DESCRIPTION FOUND"
      return nil
    end
    Rails.logger.debug "Creating board from image for #{name} - board_id: #{board_id}"
    board = board_id ? Board.find(board_id) : self.boards.new
    board.user = self.user
    board.name = self.name || "Board for Doc #{id}"
    board.token_limit = token_limit
    board.description = new_doc.processed
    board.number_of_columns = 6
    board.save!
    new_doc.update!(board_id: board.id)

    Rails.logger.debug "Creating images from description for board: #{board.id}"
    Rails.logger.debug "Description: #{new_doc.processed}"

    create_images_from_description(board)
    board.reset_layouts
    begin
      board.display_image_url = new_doc.image&.url if new_doc.image.attached?
      board.save!
    rescue => e
      Rails.logger.error "create_board_from_image **** ERROR **** \n#{e.message}\n"
      Rails.logger.error e.backtrace
    end
    # board.update!(status: "complete")
    board
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
        if should_generate_image(board_image.image, self.user, tokens_used, total_cost, true)
          board_image.update!(status: "generating")
          board_image.image.start_generate_image_job(minutes_to_wait, self.user_id, nil, board.id)
          tokens_used += 1
          total_cost += 1
          images_generated += 1
        else
          puts "Not generating image for #{board_image.image.label}"
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
    "#{base_url}/boards/#{board_id}/?returnUrl=http://localhost:8100/mymenu"
  end

  def create_images_from_description(board)
    json_description = JSON.parse(description)
    images = []
    new_board_images = []
    tokens_used = 0
    menu_item_list = []

    if json_description && json_description["menu_items"].blank?
      puts "No menu items found in description"
      return nil
    end
    json_description["menu_items"].each do |food|
      if food["name"].blank? || food["image_description"].blank?
        puts "Blank name or image description for #{food.inspect}"
        next
      end
      if food["image_description"]&.downcase&.include?("unknown")
        puts "Unknown image description for #{food["name"]}"
        puts food.inspect
        next
      end
      item_name = menu_item_name(food["name"])
      menu_item_list << item_name
      image = Image.find_by(label: item_name, user_id: self.user_id)
      image = Image.find_by(label: item_name, private: false) unless image
      image = Image.find_by(label: item_name, private: nil) unless image
      new_image = Image.create(label: item_name, image_type: self.class.name) unless image
      image = new_image if new_image
      # image.user_id = self.user_id

      unless food["image_description"].blank? || food["image_description"] == item_name
        image.image_prompt = food["image_description"]
        image.image_prompt += " #{food["description"]}" if food["description"]
      else
        image.image_prompt = "Create a high-resolution image of #{item_name}"
        image.image_prompt += " with #{food["description"]}" if food["description"]
      end
      image.private = false
      image.image_type = "Menu"
      image.display_description = image.image_prompt
      image.save!
      image.image_prompt += PROMPT_ADDITION
      new_board_image = board.add_image(image.id)
      new_board_image&.save_initial_layout if new_board_image
      images << image
      new_board_images << new_board_image if new_board_image
    end
    self.update!(item_list: menu_item_list)
    total_cost = board.cost || 0
    minutes_to_wait = 0
    images_generated = 0
    begin
      new_board_images.each_slice(8) do |board_image_slice|
        board_image_slice.each do |board_image|
          if should_generate_image(board_image.image, self.user, tokens_used, total_cost)
            board_image.update!(status: "generating")
            board_image.image.start_generate_image_job(minutes_to_wait, self.user_id, nil, board.id)
            tokens_used += 1
            total_cost += 1
            images_generated += 1
          else
            Rails.logger.info "Not generating image for #{board_image.image.label}"
            board_image.update!(status: "skipped")
          end
        end
        minutes_to_wait += 1
      end
    rescue => e
      Rails.logger.error "**** ERROR **** \n#{e.message}\n#{e.backtrace}\n"
      # board.update(status: "error") if board
      board.update(status: "error - #{e.message}\n#{e.backtrace}\n") if board
    end

    self.user.remove_tokens(tokens_used)
    board.add_to_cost(tokens_used) if board
    puts "USED #{tokens_used} tokens for #{images_generated} images"
    board
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
      board: main_board&.api_view_with_images(viewing_user),
      displayImage: docs.last&.display_url,
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

  def enhance_image_description(board_id = nil)
    board_id ||= self.boards.last&.id
    @board = Board.find_by(id: board_id) if board_id
    unless @board
      Rails.logger.error "No board found for this menu."
      puts "No board found for this menu."
      return nil
    end
    new_doc = self.docs.last
    raise "NO NEW DOC FOUND" && return unless new_doc
    # self.update!(description: new_doc.processed)
    begin
      if new_doc

        # new_processed = describe_menu(@board.display_image_url)
        # @board.update(status: "error") unless new_processed
        # @board.update!(description: new_processed) if new_processed
        restaurant_name = name || "Restaurant"
        from_text, messages_sent = clarify_image_description(new_doc.raw, restaurant_name)
        new_processed = from_text || describe_menu(@board.display_image_url)

        if valid_json?(from_text)
          @board.update!(description: from_text)
          self.prompt_used = from_text
          self.save!
        else
          puts "INVALID JSON: #{new_processed}"
          new_from_text = transform_into_json(new_processed)
          self.prompt_used = new_from_text
        end

        # new_new_processed = new_processed["menu_items"].to_json
        new_new_processed = new_processed.to_json

        new_doc.processed = new_new_processed
        new_doc.current = true
        new_doc.user_id = self.user_id
        new_doc.save!
        self.raw = new_doc.raw
        self.description = new_new_processed
        self.prompt_sent = new_processed
        self.save!

        create_board_from_image(new_doc, board_id)
      else
        Rails.logger.error "NO NEW DOC FOUND"
      end
    rescue => e
      puts "**** ERROR **** \n#{e.message}\n"
      puts e.backtrace
      Rails.logger.error "**** ERROR **** \n#{e.message}\n#{e.backtrace}\n"

      # board = Board.where(id: board_id).first if board_id
      # board = self.boards.last unless board
      # board = self.boards.create(user: self.user, name: self.name) unless board
      # board.update(status: "error") if board
      # board.update(status: "error - #{e.message}\n#{e.backtrace}\n") if board
      nil
    end
  end

  def describe_menu(url)
    unless url.present? && url.is_a?(String)
      Rails.logger.error "Invalid URL: #{url.class} - #{url}"
      return nil
    end
    menu_items = nil
    begin
      # image_data = doc.active_storage_to_data_url
      Rails.logger.debug "Image data: #{url.present?}\n Running describe_menu\n #{url}"
      response = OpenAiClient.new(open_ai_opts).describe_menu(url)
      Rails.logger.debug "describe_menu - Response: #{response}\n"
      menu_items = response[:content] if response
    rescue => e
      puts "**** OpenAiClient ERROR **** \n#{e.message}\n"
      puts e.backtrace
      Rails.logger.error "**** OpenAiClient ERROR **** \n#{e.message}\n#{e.backtrace}\n"
    end

    if response
      begin
        # Extract the "content" field from the first choice
        content = response["choices"].first["message"]["content"]

        # Remove Markdown code block formatting (e.g., ```json)
        json_content = content.gsub(/```json|```/, "").strip

        # Parse the JSON string into a Ruby hash
        menu_items = JSON.parse(json_content)
      rescue JSON::ParserError => e
        puts "Failed to parse JSON: #{e.message}"
      rescue => e
        puts "**** ERROR ****"
        puts e.message
      end
    else
      Rails.logger.error "*** ERROR - get_menu_items *** \nDid not receive valid response. Response: #{response}\n"
    end
    Rails.logger.debug "menu_items: #{menu_items}"
    menu_items
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
