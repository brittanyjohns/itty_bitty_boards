class Image < ApplicationRecord
  has_many :docs, as: :documentable

  include ImageHelper

  def create_image_doc
    new_doc_image = create_image
    
  end

  def prompt_to_send
    image_prompt || label
  end

  def open_ai_opts
    { prompt: prompt_to_send }
  end

  def speak_name
    label
  end
end
