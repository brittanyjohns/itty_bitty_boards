require "aws-sdk-s3"

s3 = Aws::S3::Client.new(region: "us-east-1")

bucket_name = "itty-bitty-boards-development"
key = "e00epy1omnmnmjqcq9z0oqsotlu5"

s3.copy_object(
  bucket: bucket_name,
  copy_source: "#{bucket_name}/#{key}",
  key: key,
  metadata_directive: "REPLACE",
  content_type: "image/svg+xml",
  content_disposition: "inline",
)

puts "Metadata updated successfully!"
