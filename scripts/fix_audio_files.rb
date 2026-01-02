# script/fix_audio_headers.rb
require "aws-sdk-s3"
require_relative "../config/environment"

RAILS_ENV = ENV.fetch("RAILS_ENV", "development")
bucket_name = ENV.fetch("S3_BUCKET", "itty-bitty-boards-#{RAILS_ENV}")
region = ENV.fetch("AWS_REGION", "us-east-1")

s3 = Aws::S3::Client.new(region: region)

puts "Checking bucket: #{bucket_name} (region: #{region})"
puts "Looking for audio objects with Content-Disposition attachment (or missing/invalid Content-Type)..."

# Helper: pick a reasonable filename for inline disposition
def inline_filename_for(key, head)
  # Prefer the filename from existing disposition if present
  cd = head.content_disposition.to_s
  if cd =~ /filename\*?=/
    # Try filename*=UTF-8''name.ext or filename="name.ext"
    if cd =~ /filename\*=(?:UTF-8'')?([^;]+)/
      return Regexp.last_match(1).gsub(/(^"|"$)/, "").strip
    end
    if cd =~ /filename="([^"]+)"/
      return Regexp.last_match(1).strip
    end
  end

  # Fallback: last path segment of key
  base = key.split("/").last
  base = "audio" if base.nil? || base.empty?

  # If no extension, add .mp3 (most of yours are mp3 even if named .aac)
  if base !~ /\.[a-z0-9]{2,5}\z/i
    base = "#{base}.mp3"
  end

  # If it ends in .aac but content type is audio/mpeg, flip to .mp3 for clarity
  if base.downcase.end_with?(".aac") && head.content_type.to_s == "audio/mpeg"
    base = base.sub(/\.aac\z/i, ".mp3")
  end

  base
end

keys_to_fix = []

# If you have a lot of objects, you should paginate.
continuation = nil
loop do
  resp = s3.list_objects_v2(bucket: bucket_name, continuation_token: continuation)
  resp.contents.each do |object|
    key = object.key

    # Skip non-audio folders / obvious non-audio keys if you want:
    # next unless key.include?("audio") || key.end_with?(".mp3", ".aac", ".m4a")

    head = s3.head_object(bucket: bucket_name, key: key)
    ct = head.content_type.to_s
    cd = head.content_disposition.to_s

    looks_audio = ct.start_with?("audio/") || key.match?(/\.(mp3|aac|m4a)\z/i)
    next unless looks_audio

    # Fix if disposition is attachment OR filename mismatch is likely OR content-type is octet-stream
    needs_fix =
      cd.downcase.include?("attachment") ||
      ct == "application/octet-stream" ||
      (ct.empty?)

    if needs_fix
      puts "Will fix: #{key}"
      puts "  current content-type: #{ct.inspect}"
      puts "  current content-disposition: #{cd.inspect}"
      keys_to_fix << key
    end
  end

  break unless resp.is_truncated
  continuation = resp.next_continuation_token
end

puts "\nFound #{keys_to_fix.length} keys to update.\n\n"

keys_to_fix.each do |key|
  head = s3.head_object(bucket: bucket_name, key: key)

  current_ct = head.content_type.to_s
  new_ct = if current_ct.start_with?("audio/")
      current_ct
    elsif key.downcase.end_with?(".m4a")
      "audio/mp4"
    elsif key.downcase.end_with?(".aac")
      "audio/aac"
    else
      # Default to mp3
      "audio/mpeg"
    end

  #   filename = inline_filename_for(key, head)
  #   new_cd = %(inline; filename="#{filename}")
  base = File.basename(filename, ".*")
  new_cd = %(inline; filename="#{base}.mp3")

  begin
    s3.copy_object(
      bucket: bucket_name,
      copy_source: "#{bucket_name}/#{key}",
      key: key,
      metadata_directive: "REPLACE",
      content_type: new_ct,
      content_disposition: new_cd,
      # Preserve encryption if present (optional, but safe)
      server_side_encryption: (head.server_side_encryption || "AES256"),
    )

    puts "Updated: #{key}"
    puts "   content-type: #{current_ct.inspect} -> #{new_ct.inspect}"
    puts "   content-disposition -> #{new_cd.inspect}"
  rescue => e
    puts " Failed: #{key} (#{e.class}: #{e.message})"
  end
end

puts "\nDone."
puts "If you serve through CloudFront, invalidate the updated paths (or wait for cache TTL)."
