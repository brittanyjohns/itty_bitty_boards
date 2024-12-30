require "aws-sdk-s3"

s3 = Aws::S3::Client.new(region: "us-east-1")

bucket_name = "itty-bitty-boards-#{Rails.env}"

# s3.copy_object(
#   bucket: bucket_name,
#   copy_source: "#{bucket_name}/#{key}",
#   key: key,
#   metadata_directive: "REPLACE",
#   content_type: "image/svg+xml",
#   content_disposition: "inline",
# )
keys = []
# List objects in the bucket
s3.list_objects_v2(bucket: bucket_name).contents.each do |object|
  key = object.key
  metadata = s3.head_object(bucket: bucket_name, key: key)
  if metadata.content_type == "application/octet-stream"
    puts "Key with wrong content-type: #{key}"
    keys << key
  end
end

# # write the keys to a file
# File.open("keys.txt", "w") { |file| file.write(keys.join("\n")) }
# puts "Keys written to keys.txt"
# `open keys.txt`

keys.each do |key|
  s3.copy_object(
    bucket: bucket_name,
    copy_source: "#{bucket_name}/#{key}",
    key: key,
    metadata_directive: "REPLACE",
    content_type: "image/svg+xml",
    content_disposition: "inline",
  )
  puts "Updated key: #{key}"
end
puts "Done"
