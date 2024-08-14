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

  def create_board_from_image(new_doc, board_id = nil)
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
    puts "Board created from image description: #{board.id}\ndisplay_url: #{new_doc.display_url}\n"
    # board.update_user_docs
    Rails.logger.info "Not updating user docs"
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
      puts "Image prompt: #{image.image_prompt}"
      image.display_description = image.image_prompt
      image.save!
      image.image_prompt += PROMPT_ADDITION
      puts "Image Id: #{image.id}\n"
      new_board_image = board.add_image(image.id)
      new_board_image&.save_initial_layout_for_menu if new_board_image
      images << image
      new_board_images << new_board_image if new_board_image
    end
    #     "237 error - undefined method `save_initial_layout' for an instance of BoardImage
    # ["/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/activemodel-7.1.3/lib/active_model/attribute_methods.rb:489:in
    # `method_missing'", "/Users/brittanyjohns/Projects/itty_bitty_boards/app/models/menu.rb:140:in `block in create_images_from_description'",
    # "/Users/brittanyjohns/Projects/itty_bitty_boards/app/models/menu.rb:107:in `each'", "/Users/brittanyjohns/Projects/itty_bitty_boards/app/models/menu.rb:107:in `create_images_from_description'", "/Users/brittanyjohns/Projects/itty_bitty_boards/app/models/menu.rb:61:in `create_board_from_image'", "/Users/brittanyjohns/Projects/itty_bitty_boards/app/models/menu.rb:236:in `enhance_image_description'", "/Users/brittanyjohns/Projects/itty_bitty_boards/app/sidekiq/enhance_image_description_job.rb:8:in `perform'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/sidekiq-7.2.1/lib/sidekiq/processor.rb:210:in `execute_job'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/sidekiq-7.2.1/lib/sidekiq/processor.rb:180:in `block (4 levels) in process'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/sidekiq-7.2.1/lib/sidekiq/middleware/chain.rb:180:in `traverse'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/sidekiq-7.2.1/lib/sidekiq/middleware/chain.rb:183:in `block in traverse'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/sidekiq-7.2.1/lib/sidekiq/metrics/tracking.rb:26:in `track'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/sidekiq-7.2.1/lib/sidekiq/metrics/tracking.rb:126:in `call'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/sidekiq-7.2.1/lib/sidekiq/middleware/chain.rb:182:in `traverse'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/sidekiq-7.2.1/lib/sidekiq/middleware/chain.rb:173:in `invoke'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/sidekiq-7.2.1/lib/sidekiq/processor.rb:179:in `block (3 levels) in process'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/sidekiq-7.2.1/lib/sidekiq/processor.rb:140:in `block (6 levels) in dispatch'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/sidekiq-7.2.1/lib/sidekiq/job_retry.rb:113:in `local'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/sidekiq-7.2.1/lib/sidekiq/processor.rb:139:in `block (5 levels) in dispatch'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/sidekiq-7.2.1/lib/sidekiq/rails.rb:16:in `block in call'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/activesupport-7.1.3/lib/active_support/reloader.rb:77:in `block in wrap'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/activesupport-7.1.3/lib/active_support/execution_wrapper.rb:92:in `wrap'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/activesupport-7.1.3/lib/active_support/reloader.rb:74:in `wrap'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/sidekiq-7.2.1/lib/sidekiq/rails.rb:15:in `call'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/sidekiq-7.2.1/lib/sidekiq/processor.rb:135:in `block (4 levels) in dispatch'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/sidekiq-7.2.1/lib/sidekiq/processor.rb:271:in `stats'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/sidekiq-7.2.1/lib/sidekiq/processor.rb:130:in `block (3 levels) in dispatch'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/sidekiq-7.2.1/lib/sidekiq/job_logger.rb:13:in `call'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/sidekiq-7.2.1/lib/sidekiq/processor.rb:129:in `block (2 levels) in dispatch'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/sidekiq-7.2.1/lib/sidekiq/job_retry.rb:80:in `global'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/sidekiq-7.2.1/lib/sidekiq/processor.rb:128:in `block in dispatch'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/sidekiq-7.2.1/lib/sidekiq/job_logger.rb:39:in `prepare'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/sidekiq-7.2.1/lib/sidekiq/processor.rb:127:in `dispatch'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/sidekiq-7.2.1/lib/sidekiq/processor.rb:178:in `block (2 levels) in process'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/sidekiq-7.2.1/lib/sidekiq/processor.rb:177:in `handle_interrupt'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/sidekiq-7.2.1/lib/sidekiq/processor.rb:177:in `block in process'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/sidekiq-7.2.1/lib/sidekiq/processor.rb:176:in `handle_interrupt'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/sidekiq-7.2.1/lib/sidekiq/processor.rb:176:in `process'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/sidekiq-7.2.1/lib/sidekiq/processor.rb:82:in `process_one'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/sidekiq-7.2.1/lib/sidekiq/processor.rb:72:in `run'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/sidekiq-7.2.1/lib/sidekiq/component.rb:10:in `watchdog'", "/Users/brittanyjohns/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/sidekiq-7.2.1/lib/sidekiq/component.rb:19:in `block in safe_thread'"]
    # "
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
    # board.position_all_board_images
    # board.calucate_grid_layout
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
      status: main_board&.status,
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

  def enhance_image_description(board_id)
    new_doc = self.docs.last
    raise "NO NEW DOC FOUND" && return unless new_doc
    self.update!(description: new_doc.processed)
    begin
      if !new_doc.raw.blank?
        new_doc.processed, messages_sent = clarify_image_description(new_doc.raw)
        puts "Processed: #{new_doc.processed}\n"
        puts "Messages sent: #{messages_sent}\n"
        Rails.logger.info "Processed: #{new_doc.processed}\n"
        Rails.logger.info "Messages sent: #{messages_sent}\n"
        return nil unless new_doc.processed
        new_doc.current = true
        new_doc.user_id = self.user_id
        new_doc.save!
        self.raw = new_doc.raw
        self.description = new_doc.processed
        self.prompt_sent = messages_sent
        self.save!

        create_board_from_image(new_doc, board_id)
      else
        puts "Image description invaild: #{description}\n"
        description
      end
    rescue => e
      puts "**** ERROR **** \n#{e.message}\n#{e.backtrace}\n"
      board = Board.where(id: board_id).first if board_id
      board = self.boards.last unless board
      board = self.boards.create(user: self.user, name: self.name) unless board
      # board.update(status: "error") if board
      board.update(status: "237 error - #{e.message}\n#{e.backtrace}\n") if board
      puts "UPDATE BOARD: #{board.inspect}"
      nil
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
