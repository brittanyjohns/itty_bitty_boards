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
  default_scope { includes(:docs) }
  belongs_to :user, optional: true
  has_many :docs, as: :documentable
  has_many :board_images, dependent: :destroy
  has_many :boards, through: :board_images

  include ImageHelper

  def create_image_doc(user_id = nil)
    puts ">>>>>>>>> **** create_image_doc ****\n"
    new_doc_image = create_image(user_id)
    self.image_prompt = prompt_to_send
    self.save!
  end

  def finished?
    status == "finished"
  end

  def generating?
    status == "generating"
  end

  def display_image(viewing_user = nil)
    if viewing_user
      img = viewing_user.display_doc_for_image(self)&.image
      if img
        puts "DISPLAY IMAGE FOUND: #{img}\n"
        img
      else
        puts "DISPLAY IMAGE NOT FOUND: #{docs.current.first&.image}\n"
        docs.current.first&.image
      end
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
    UserDoc.where(user_id: user.id, doc_id: docs.pluck(:id)).first&.doc
  end

  def prompt_to_send
    image_prompt.blank? ? "#{prompt_for_label} #{label}" : image_prompt
  end

  def prompt_for_label
    "Generate an image of"
  end

  def start_generate_image_job(start_time = 0)
    puts "start_generate_image_job: #{label}"
    self.update(status: "generating")

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
