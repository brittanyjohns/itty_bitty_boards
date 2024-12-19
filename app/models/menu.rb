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

  scope :predefined, -> { where(predefined: true) }
  scope :user_defined, -> { where(predefined: false) }

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
    board = board_id ? Board.find(board_id) : self.boards.new
    board.user = self.user
    board.name = self.name || "Board for Doc #{id}"
    board.token_limit = token_limit
    board.description = new_doc.processed
    board.number_of_columns = 6
    board.save!
    new_doc.update!(board_id: board.id)

    puts "Creating images from description for board: #{board.id}"
    puts "Description: #{new_doc.processed}"

    create_images_from_description(board)
    board.reset_layouts

    board.display_image_url = new_doc.image&.url if new_doc.image.attached?
    board.save!
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
        if should_generate_image(board_image.image, self.user, tokens_used, total_cost)
          board_image.update!(status: "generating")
          puts "Generating image for #{board_image.image.label} - user: #{self.user_id}"
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
    @user.remove_tokens(tokens_used)
    puts "USED #{tokens_used} tokens for #{images_generated} images"
    board.add_to_cost(tokens_used) if board
  end

  def create_images_from_description(board)
    json_description = JSON.parse(description)
    images = []
    new_board_images = []
    tokens_used = 0
    menu_item_list = []

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
      image.user_id = self.user_id

      unless food["image_description"].blank? || food["image_description"] == item_name
        image.image_prompt = food["image_description"]
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
            puts "Not generating image for #{board_image.image.label}"
            board_image.update!(status: "skipped")
          end
        end
        minutes_to_wait += 1
      end
    rescue => e
      puts "**** ERROR **** \n#{e.message}\n#{e.backtrace}\n"
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
      token_limit: token_limit,
      board: main_board&.api_view_with_images(viewing_user),
      displayImage: docs.last&.display_url,
      can_edit: viewing_user.admin? || viewing_user.id == user_id,
      user_id: user_id,
      status: main_board&.status || "error",
      created_at: created_at,
      updated_at: updated_at,
      has_generating_images: main_board&.has_generating_images?,
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
    puts "Enhancing image description for #{name} - board_id: #{board_id}"
    new_doc = self.docs.last
    if valid_json?(description)
      puts "DESCRIPTION Valid JSON: #{description}"
    end
    raise "NO NEW DOC FOUND" && return unless new_doc
    self.update!(description: new_doc.processed)
    begin
      if new_doc.processed
        # new_doc.processed, messages_sent = clarify_image_description(new_doc.raw)
        puts "Processed: #{new_doc.processed}\n"
        # puts "Messages sent: #{messages_sent}\n"
        Rails.logger.info "Processed: #{new_doc.processed}\n"
        # Rails.logger.info "Messages sent: #{messages_sent}\n"
        # return nil unless new_doc.processed

        if new_doc.attached_image_url.blank?
          puts "No attached image url"
        else
          puts "Attached image url: #{new_doc.attached_image_url.class}"
        end
        new_processed = describe_menu(new_doc)
        puts "New processed: #{new_processed}\n"
        # new_new_processed, messages_sent = clarify_image_description(new_processed)

        # if valid_json?(new_processed)
        #   puts "Valid JSON: #{new_processed}"
        #   new_processed = JSON.parse(new_processed)
        # else
        #   puts "INVALID JSON: #{new_processed}"
        #   new_processed = transform_into_json(new_processed)
        # end

        # new_new_processed = new_processed["menu_items"].to_json
        new_new_processed = new_processed.to_json

        Rails.logger.debug "new_new_processed: #{new_processed}\n"
        new_doc.processed = new_new_processed
        new_doc.current = true
        new_doc.user_id = self.user_id
        new_doc.save!
        self.raw = new_doc.raw
        self.description = new_new_processed
        self.save!

        create_board_from_image(new_doc, board_id)
      else
        Rails.logger.error "Image description invaild: #{description}\n"
        description
      end
    rescue => e
      puts "**** ERROR **** \n#{e.message}\n"
      puts e.backtrace
      # board = Board.where(id: board_id).first if board_id
      # board = self.boards.last unless board
      # board = self.boards.create(user: self.user, name: self.name) unless board
      # board.update(status: "error") if board
      # board.update(status: "error - #{e.message}\n#{e.backtrace}\n") if board
      nil
    end
  end

  def describe_menu(doc)
    image_data = doc.active_storage_to_data_url
    puts "Image data: #{image_data.present?}\n Running describe_menu\n"
    response = OpenAiClient.new(open_ai_opts).describe_menu(image_data)
    menu_items = response[:content]
    puts "Menu items: #{menu_items}\n"
    if response
      # if valid_json?(menu_items)
      #   menu_items = JSON.parse(menu_items)
      # else
      #   puts "INVALID JSON: #{menu_items}"
      #   menu_items = transform_into_json(menu_items)
      # end

      begin
        # Extract the "content" field from the first choice
        content = response["choices"].first["message"]["content"]

        # Remove Markdown code block formatting (e.g., ```json)
        json_content = content.gsub(/```json|```/, "").strip

        # Parse the JSON string into a Ruby hash
        menu_items = JSON.parse(json_content)

        # Output the parsed menu items
        puts "Menu Items:"
        menu_items["menu_items"].each do |item|
          puts " - #{item["name"]}: #{item["description"]}"
        end
      rescue JSON::ParserError => e
        puts "Failed to parse JSON: #{e.message}"
      rescue => e
        puts "**** ERROR ****"
        puts e.message
      end
    else
      Rails.logger.error "*** ERROR - get_menu_items *** \nDid not receive valid response. Response: #{response}\n"
    end
    puts "menu_items: #{menu_items}"
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
