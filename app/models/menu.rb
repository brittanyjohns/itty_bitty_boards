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

  include ImageHelper

  validates :name, presence: true

  accepts_nested_attributes_for :docs

  def label
    name
  end

  def doc_boards
    docs.map(&:board).compact
  end

  def create_board_from_image(new_doc)
    board = self.boards.new
    board.user = self.user
    board.name = self.name || "Board for Doc #{id}"
    board.description = new_doc.processed_text
    board.save!
    new_doc.update!(board_id: board.id)

    create_images_from_description(board)
    board
  end

  def create_images_from_description(board)
    puts "**** create_images_from_description **** \n"
    json_description = JSON.parse(description)
    images = []
    mintues_to_wait = 0
    json_description["menu_items"].each do |food|
      puts "food: #{food}\n"
      item_name = menu_item_name(food["name"])
      puts "Finding or creating image for #{item_name}\n"
      image = Image.find_or_create_by!(label: item_name)
      unless food["image_description"].blank? || food["image_description"] == item_name
        image.image_prompt = food["image_description"]
      else
        image.image_prompt = "Create an image of #{item_name}"
        image.image_prompt += " with #{food["description"]}" if food["description"]
      end
      puts "\n\n\n***image.image_prompt: #{image.image_prompt}\n"
      image.private = false
      image.save!
      board.add_image(image.id)
      images << image

      # image.start_generate_image_job(start_time) unless image.display_image.attached?
    end
    images.each_slice(5) do |image_slice|
      image_slice.each do |image|
        image.start_generate_image_job(mintues_to_wait)
      end
      mintues_to_wait += 1
    end
    tokens_used = mintues_to_wait # one token per 5 images
    self.user.remove_tokens(tokens_used)
  end

  def menu_item_name(item_name)
    item_name.downcase!
    # Strip out any non-alphanumeric characters
    item_name.gsub(/[^a-z ]/i, '')
    puts "item_name: #{item_name}\n"
    item_name
  end

  def run_image_description_job
    puts "**** run_image_description_job **** \n"
    EnhanceImageDescriptionJob.perform_async(self.id)
  end
    

  def enhance_image_description
    new_doc = self.docs.last
    puts "NO NEW DOC FOUND\n" && return unless new_doc
    # return unless image_description
    puts "processed_text before: #{new_doc.processed_text}\n raw_text: #{new_doc.raw_text}\n"

    if !new_doc.raw_text.blank?
      new_doc.processed_text = clarify_image_description(new_doc.raw_text)
      new_doc.current = true
      new_doc.user_id = self.user_id
      new_doc.save!
      self.description = new_doc.processed_text
      puts "Image description after: #{description}\n"
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
    description_prompt
  end

  def description_prompt
    "Please describe the food and drink options on this kid's restaurant menu."
  end

end
