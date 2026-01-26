class RecategorizeImagesJob
  include Sidekiq::Job

  def perform(image_type, image_ids)
    images = nil
    if image_type == "Image"
      images = Image.where(id: image_ids)
      return true
    elsif image_type == "BoardImage"
      images = BoardImage.where(id: image_ids)
    end
    if images.blank?
      puts "Images not found with ids: #{image_ids}"
      return
    end
    images.each do |image|
      if image_type == "Image"
        image.reset_part_of_speech!
      elsif image_type == "BoardImage"
        image.reset_part_of_speech_and_bg_color!
      end
    end
    puts "Recategorized #{image_type} images with IDs #{image_ids} to their respective parts_of_speech"
    true
  end
end
