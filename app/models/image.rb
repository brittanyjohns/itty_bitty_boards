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
#
class Image < ApplicationRecord
  belongs_to :user, optional: true
  has_many :docs, as: :documentable

  include ImageHelper

  def create_image_doc(user_id = nil)
    puts ">>>>>>>>> **** create_image_doc ****\n"
    new_doc_image = create_image(self)
    self.image_prompt = prompt_to_send
    self.save!
  end

  def display_image(user = nil)
    if user
      docs_for_user(user).current.first&.image
    elsif docs.current.any? && docs.current.first.image&.attached?
      docs.current.first.image
    else
      nil
    end
  end

  def docs_for_user(user)
    if user.admin?
      docs
    else
      docs.where(user_id: [user.id, nil])
    end
  end

  def current_doc_for_user(user)
    docs_for_user(user).current.first
  end

  def prompt_to_send
    image_prompt.blank? ? "#{prompt_for_label} #{label}" : image_prompt
  end

  def prompt_for_label
    "Generate an image of"
  end

  def start_generate_image_job(start_time = 0)
    puts "start_generate_image_job: #{label}"

    GenerateImageJob.perform_in(start_time.minutes, id)
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
