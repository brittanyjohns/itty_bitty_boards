class Image < ApplicationRecord
  has_many :docs, as: :documentable

  include ImageHelper

  def create_image_doc
    new_doc_image = create_image
    self.image_prompt = prompt_to_send
    self.save!
  end

  def display_image
      if docs.current.any? && docs.current.first.image.attached?
      docs.current.first.image
    else
      nil
    end
  end

  def prompt_to_send
    image_prompt.empty? ? "#{prompt_for_label} #{label}" : image_prompt
  end

  def prompt_for_label
    "Generate an image of"
  end

  def open_ai_opts
    puts "open_ai_opts: #{label}"
    puts "Sending prompt: #{prompt_to_send}"
    { prompt: prompt_to_send }
  end

  def speak_name
    label
  end

  def self.searchable_images_for(user = nil)
    if user
      Image.where(private: false).or(Image.where(user_id: user.id)).or(Image.where(user_id: nil, private: false))
    else
      Image.where(private: false).or(Image.where(user_id: nil, private: false))
    end
  end
end
