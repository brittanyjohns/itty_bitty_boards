class RecategorizeImagesJob
  include Sidekiq::Job

  def perform(image_type, image_ids)
    images = nil
    if image_type == "Image"
      images = Image.where(id: image_ids)
      return true
    elsif image_type == "BoardImage"
      images = BoardImage.includes(:image).where(id: image_ids)
    end
    if images.blank?
      puts "Images not found with ids: #{image_ids}"
      return
    end
    images.each do |image|
      if image.data && image.data["categorization_completed"]
        puts "Skipping recategorization for #{image_type} ID #{image.id} as it is already categorized."
        next
      end
      puts "Recategorizing #{image_type} ID #{image.id} with label '#{image.label}'"
      if image_type == "Image"
        image.reset_part_of_speech!
      elsif image_type == "BoardImage"
        image.reset_part_of_speech_and_bg_color!
      end
      image.data ||= {}
      image.data["categorization_completed"] = true
      image.save!
    end
    puts "Recategorized #{image_type} images with IDs #{image_ids} to their respective parts_of_speech"
    true
  end
end
