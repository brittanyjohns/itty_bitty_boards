# == Schema Information
#
# Table name: images
#
#  id                  :bigint           not null, primary key
#  label               :string
#  image_prompt        :text
#  display_description :text
#  private             :boolean
#  user_id             :integer
#  generate_image      :boolean          default(FALSE)
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  status              :string
#  error               :string
#  revised_prompt      :string
#  image_type          :string
#  open_symbol_status  :string           default("active")
#
class Image < ApplicationRecord
  normalizes :label, with: -> label { label.downcase.strip }
  attr_accessor :temp_prompt
  default_scope { includes(:docs) }
  belongs_to :user, optional: true
  has_many :docs, as: :documentable, dependent: :destroy
  has_many :board_images, dependent: :destroy
  has_many :boards, through: :board_images

  PROMPT_ADDITION = " Styled as a simple cartoon illustration."

  include ImageHelper

  scope :with_image_docs_for_user, -> (userId) { joins(:docs).where("docs.documentable_id = images.id AND docs.documentable_type = 'Image' AND docs.user_id = ?", userId) }
  # scope :with_image_docs_for_user, -> (user) { includes(:docs).merge(Doc.for_user(user)) }
  scope :menu_images, -> { where(image_type: "Menu") }
  scope :non_menu_images, -> { where(image_type: nil) }
  scope :public_img, -> { where(private: [false, nil]).or(Image.where(user_id: nil)) }
  scope :created_in_last_2_hours, -> { where("created_at > ?", 2.hours.ago) }
  scope :skipped, -> { where(open_symbol_status: "skipped") }

  def create_image_doc(user_id = nil)
    response = create_image(user_id)
    # self.image_prompt = prompt_to_send
  end

  def menu?
    image_type == "Menu"
  end

  def finished?
    status == "finished"
  end

  def generating?
    status == "generating"
  end

  def self.open_symbol_statuses
    ["active", "skipped"]
  end

  def generate_matching_symbol(limit = 1)
    return if open_symbol_status == "skipped"
    query = label&.downcase
    response = OpenSymbol.generate_symbol(query)

    if response
      symbols = JSON.parse(response)
      symbols_count = symbols.count
      puts "Found symbols...#{symbols_count}"
      puts "Limiting to #{limit} symbols"
      count = 0
      skipped_count = 0
      begin
      symbols.each do |symbol|
        existing_symbol = OpenSymbol.find_by(original_os_id: symbol["id"])
        if existing_symbol || OpenSymbol::IMAGE_EXTENSIONS.exclude?(symbol["extension"])
          puts "Symbol already exists: #{existing_symbol&.id} Or not an image: #{symbol["extension"]}"
          new_symbol = existing_symbol
        else
        break if count >= limit
        new_symbol =
        OpenSymbol.create!(
          name: symbol["name"],
          image_url: symbol["image_url"],
          label: query,
          search_string: symbol["search_string"],
          symbol_key: symbol["symbol_key"],
          locale: symbol["locale"],
          license_url: symbol["license_url"],
          license: symbol["license"],
          original_os_id: symbol["id"],
          repo_key: symbol["repo_key"],
          unsafe_result: symbol["unsafe_result"],
          protected_symbol: symbol["protected_symbol"],
          use_score: symbol["use_score"],
          relevance: symbol["relevance"],
          extension: symbol["extension"],
          enabled: symbol["enabled"]
        )
        end
        symbol_name = new_symbol.name.parameterize if new_symbol
        if new_symbol && should_create_symbol_image?(symbol_name)
          count += 1
          downloaded_image = new_symbol.get_downloaded_image
          new_image_doc = self.docs.create!(processed: symbol_name, raw: new_symbol.search_string, source_type: "OpenSymbol")
          new_image_doc.image.attach(io: downloaded_image, filename: "#{symbol_name}-symbol-#{new_symbol.id}.#{new_symbol.extension}")
        else
          skipped_count += 1
        end
        total = count + skipped_count
        if total >= symbols_count
          puts "Skipped all symbols"
          self.update!(open_symbol_status: "skipped")
          break
        end
      end
      symbols
      rescue => e
        puts "Error creating symbols: #{e.message}\n\n#{e.backtrace.join("\n")}"
      end
    end
  end

  def should_create_symbol_image?(symbol_name)
    return false if symbol_name.blank?
    symbol_name_like_label?(symbol_name) && !doc_text_matches(symbol_name)
  end

  def symbol_name_like_label?(symbol_name)
    return false if symbol_name.blank?
    result = false
    label.split(" ").each do |label_word|
      result = symbol_name.split("-").any? { |word| label_word.downcase.include?(word) }
      break if result
    end
    result
  end

  def doc_text_matches(symbol_name)
    return false if symbol_name.blank?
    docs.unscoped.any? { |doc| doc.processed === symbol_name }
  end

  def self.destroy_duplicate_images
    Image.all.group_by(&:label).each do |label, images|
      puts "label: #{label} - #{images.count}"
      # Skip the first image (which we want to keep) and destroy the rest
      images.drop(1).each(&:destroy)

    end
  end

  def doc_exists_for_user?(user)
    docs.where(user_id: user.id).any?
  end

  def label_param
    label&.gsub(" ", "+")
  end

  def display_image(viewing_user = nil)
    if viewing_user
      img = viewing_user.display_doc_for_image(self)&.image
      if img
        return img
      end
    end
    if docs.current.any? && docs.current.last.image&.attached?
      return docs.current.last.image
    end
    if docs.any? && docs.last.image&.attached?
      return docs.last.image
    end
    nil
  end

  def display_label
    label&.titleize&.truncate(27, separator: ' ')
  end

  def current_doc_for_user(user)
    UserDoc.where(user_id: user.id, doc_id: docs.pluck(:id)).first&.doc
  end

  def prompt_to_send
    return temp_prompt if temp_prompt.present?
    image_prompt.blank? ? "#{prompt_for_label} #{label}" : image_prompt
  end

  def prompt_for_label
    "Generate an image of"
  end

  def start_generate_image_job(start_time = 0, user_id_to_set = nil, image_prompt_to_set = nil)
    user_id_to_set ||= user_id
    puts "start_generate_image_job: #{label} - #{user_id_to_set} - #{image_prompt_to_set}"
    GenerateImageJob.perform_in(start_time.minutes, id, user_id_to_set, image_prompt_to_set)
  end

  def self.run_generate_image_job_for(images)
    start_time = 0
    images.each_slice(5) do |images_slice|
      puts "start_time: #{start_time}"
      puts "images_slice: #{images_slice.map(&:label)}"
      images_slice.each do |image|
        image.start_generate_image_job(start_time)
      end
      start_time += 2
    end
  end

  def open_ai_opts
    prompt = prompt_to_send
    puts "Sending prompt: #{prompt}"
    { prompt: prompt }
  end

  def speak_name
    label
  end

  def prompt_addition
    if image_type == "Menu"
      image_prompt.include?(Menu::PROMPT_ADDITION) ? "" : Menu::PROMPT_ADDITION
    else
      # image_prompt.include?(PROMPT_ADDITION) ? "" : PROMPT_ADDITION
      ""
    end
  end

  def self.searchable_menu_items_for(user = nil)
    if user
      Image.with_image_docs_for_user(user).menu_images.or(Image.with_image_docs_for_user(user).where(user_id: user.id)).distinct
    else
      Image.menu_images.public_img.distinct
    end
  end

  def self.searchable_images_for(user, only_user_images = false)
    if only_user_images
      puts "only_user_images"
      Image.non_menu_images.with_image_docs_for_user(user).or(Image.where(user_id: user.id)).distinct
    else
      Image.non_menu_images.with_image_docs_for_user(user).or(Image.where(user_id: user.id)).or(Image.public_img.non_menu_images).distinct
    end
  end
end
