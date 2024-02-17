namespace :voices do
  desc "TODO"
  task create: :environment do

    images_with_no_audio = Image.without_attached_audio_files
    if images_with_no_audio.count == 0
      puts "No images with no audio files"
      return
    end
    limit = 3
    puts "images_with_no_audio.count: #{images_with_no_audio.count}"
    images_with_no_audio.in_batches(of: limit) do |batch|
      batch.each do |image|
        image.save_audio_file_to_s3!
        sleep 3
        limit -= 1
      end
      break if limit == 0
    end
  end

end
