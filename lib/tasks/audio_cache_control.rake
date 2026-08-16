# Backfill Cache-Control on blobs already in S3.
#
# `config/storage.yml` sets `upload.cache_control` on the `amazon` service, but
# that only applies at PUT time — every object uploaded before it stays with no
# Cache-Control header, so the browser and CloudFront keep re-fetching an mp3
# whose bytes can never change. This rewrites the header in place with a
# same-key copy (S3 has no "set metadata" verb; COPY onto itself with
# REPLACE is the documented way).
#
#   bin/rails audio:backfill_cache_control                 # audio blobs, dry run
#   bin/rails audio:backfill_cache_control APPLY=1         # actually write
#   bin/rails audio:backfill_cache_control APPLY=1 ALL=1   # every public blob
#
# Safe to re-run: copying an object onto itself with identical bytes is
# idempotent, and blobs that already carry the header are skipped.
namespace :audio do
  CACHE_CONTROL = "public, max-age=31536000, immutable".freeze

  desc "Backfill Cache-Control on existing S3 blobs (APPLY=1 to write, ALL=1 for every content type)"
  task backfill_cache_control: :environment do
    apply = ENV["APPLY"] == "1"
    every = ENV["ALL"] == "1"

    service = ActiveStorage::Blob.service
    unless service.respond_to?(:bucket)
      abort "Active Storage service #{service.class} is not S3-backed — nothing to do."
    end

    scope = ActiveStorage::Blob.all
    scope = scope.where("content_type LIKE ?", "audio/%") unless every

    total = scope.count
    puts "#{apply ? "Applying" : "Dry run"} over #{total} blob(s)#{every ? "" : " (audio only)"}."

    updated = 0
    skipped = 0
    missing = 0

    scope.find_each.with_index do |blob, i|
      object = service.bucket.object(blob.key)

      unless object.exists?
        missing += 1
        next
      end

      if object.cache_control.to_s == CACHE_CONTROL
        skipped += 1
        next
      end

      if apply
        # copy_from onto the same key with REPLACE rewrites the metadata
        # without re-uploading from our side.
        object.copy_from(
          object,
          cache_control: CACHE_CONTROL,
          content_type: blob.content_type,
          metadata_directive: "REPLACE",
          acl: "public-read"
        )
      end

      updated += 1
      puts "  [#{i + 1}/#{total}] #{blob.key} (#{blob.content_type})" if (updated % 50).zero? || total < 50
    rescue StandardError => e
      warn "  FAILED #{blob.key}: #{e.class}: #{e.message}"
    end

    puts "Done. #{apply ? "updated" : "would update"}=#{updated} already_set=#{skipped} missing_in_bucket=#{missing}"
    puts "Re-run with APPLY=1 to write." unless apply
  end
end
