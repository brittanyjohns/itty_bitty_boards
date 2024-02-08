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
#
class Menu < ApplicationRecord
  belongs_to :user
  has_many :boards, as: :parent, dependent: :destroy
  has_many :docs, as: :documentable, dependent: :destroy
  has_many :board_images, through: :boards
  has_many :images, through: :board_images

  PROMPT_ADDITION = " The dish should be presented looking fresh and appetizing on a simple, uncluttered background. The lighting should be natural and warm, enhancing the appeal of the food and creating a welcoming atmosphere. Ensure the image looks realistic, like an actual photograph from a family restaurant's menu."
  include ImageHelper

  validates :name, presence: true

  accepts_nested_attributes_for :docs

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

  def create_board_from_image(new_doc)
    board = self.boards.new
    board.user = self.user
    board.name = self.name || "Board for Doc #{id}"
    board.token_limit = token_limit
    board.description = new_doc.processed
    board.save!
    new_doc.update!(board_id: board.id)

    create_images_from_description(board)
    board
  end

  def rerun_image_description_job
    @user = self.user
    board = self.boards.last
    tokens_used = 0
    total_cost = board.cost || 0

    minutes_to_wait = 0
    board.images.each_slice(5) do |image_slice|
      minutes_to_wait += 1
      image_slice.each do |image|
        next unless should_generate_image(image, @user, tokens_used, total_cost)
        image.start_generate_image_job(minutes_to_wait, @user.id)
        tokens_used += 1
        total_cost += 1
      end
    end
    @user.remove_tokens(tokens_used)
    board.add_to_cost(tokens_used) if board
  end

  def create_images_from_description(board)
    json_description = JSON.parse(description)
    images = []
    new_images = []
    tokens_used = 0
    json_description["menu_items"].each do |food|
      if food["name"].blank? || food["image_description"].include?("Unknown")
        puts "No name or image description for food item\n"
        next
      end
      item_name = menu_item_name(food["name"])
      image = Image.find_by(label: item_name, user_id: self.user_id)
      image = Image.find_by(label: item_name, private: false) unless image
      image = Image.find_by(label: item_name, private: nil) unless image
      new_image = Image.create(label: item_name) unless image
      image = new_image if new_image


      unless food["image_description"].blank? || food["image_description"] == item_name
        image.image_prompt = food["image_description"]
      else
        image.image_prompt = "Create a high-resolution image of #{item_name}"
        image.image_prompt += " with #{food["description"]}" if food["description"]
      end
      image.private = false
      image.image_type = self.class.name
      image.display_description = image.image_prompt
      image.save!
      image.image_prompt += PROMPT_ADDITION
      board.add_image(image.id)
      images << image
      new_images << new_image if new_image
    end
    total_cost = board.cost || 0
    minutes_to_wait = 0
    new_images.each_slice(5) do |image_slice|
      minutes_to_wait += 1
      image_slice.each do |image|
        next unless should_generate_image(image, self.user, tokens_used, total_cost)
        image.start_generate_image_job(minutes_to_wait, self.user_id)
        tokens_used += 1
        total_cost += 1
      end
    end
    self.user.remove_tokens(tokens_used)
    board.add_to_cost(tokens_used) if board
  end

  def should_generate_image(image, user, tokens_used, total_cost = 0)
    return false if image.doc_exists_for_user?(user)
    return false if user.tokens <= tokens_used
    return false if token_limit <= total_cost
    true
  end

  def menu_item_name(item_name)
    item_name.downcase!
    # Strip out any non-alphanumeric characters
    item_name.gsub(/[^a-z ]/i, '')
    item_name
  end

  def run_image_description_job
    EnhanceImageDescriptionJob.perform_async(self.id)
  end
    

  def enhance_image_description
    new_doc = self.docs.last
    puts "NO NEW DOC FOUND\n" && return unless new_doc

    if !new_doc.raw.blank?
      new_doc.processed = clarify_image_description(new_doc.raw)
      new_doc.current = true
      new_doc.user_id = self.user_id
      new_doc.save!
      self.description = new_doc.processed
      puts "**** ERROR **** \nNo image description provided.\n" unless description
      self.save!

      create_board_from_image(new_doc)
    else
      puts "Image description invaild: #{description}\n"
      description
    end
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
