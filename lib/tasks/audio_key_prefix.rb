# lib/tasks/audio_key_prefix.rake
namespace :active_storage do
  desc "Move existing audio blobs under a key prefix (copy + update)"
  task prefix_audio_keys: :environment do
    prefix = ENV.fetch("PREFIX", "audio-v1")

    scope = ActiveStorage::Blob.where(content_type: ["audio/mpeg", "audio/mp4", "audio/wav", "audio/x-wav", "audio/aac", "audio/ogg", "audio/webm"])

    puts "Found #{scope.count} audio blobs..."

    scope.find_each do |blob|
      old_key = blob.key
      next if old_key.start_with?("uploads/#{prefix}/")

      filename = blob.filename.to_s
      new_key = "uploads/#{prefix}/#{SecureRandom.uuid}/#{filename}"

      puts "Moving blob #{blob.id}: #{old_key} -> #{new_key}"

      # Download existing object
      data = blob.download

      # Upload to new key
      blob.service.upload(new_key, StringIO.new(data), checksum: blob.checksum, content_type: blob.content_type)

      # Update DB to point to new key
      blob.update!(key: new_key)

      # Optional: delete the old object (I recommend NOT deleting immediately)
      # blob.service.delete(old_key)
    rescue => e
      warn "FAILED blob #{blob.id}: #{e.class} #{e.message}"
    end

    puts "Done."
  end
end
