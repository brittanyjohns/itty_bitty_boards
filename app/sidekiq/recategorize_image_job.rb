class RecategorizeImageJob
  include Sidekiq::Job

  def perform(image_type, image_id)
    image = nil
    if image_type == "Image"
      image = Image.find_by(id: image_id)
      image.reset_part_of_speech!
    elsif image_type == "BoardImage"
      image = BoardImage.find_by(id: image_id)
      image.reset_part_of_speech_and_bg_color!
    end
    if image.blank?
      puts "Image not found with id: #{image_id}"
      return
    end
    puts "Recategorized image ID #{image_id} to part_of_speech: #{image.part_of_speech}"
    true
  end
end
