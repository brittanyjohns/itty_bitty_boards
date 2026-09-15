# A printable sold as its own product rather than as a board — first AAC DEVICE
# TAGS: an editable Canva template in a few designs, where the buyer adds their
# own QR. BoardPrintable is board-only (it walks a board tree and renders pages);
# this record holds a product whose art was DESIGNED, not rendered.
#
# Three things live here, each in its own place:
#
#   * `artworks`  — the product's design images, each with an admin label in blob
#                   metadata. Marketing source art: what a scene mockup warps
#                   into a slot. Never a buyer file.
#   * `downloads` — what a buyer receives (PDF/PNG). Never a mockup.
#   * `canva_templates` — editable Canva links, its own column and validated by
#                   the shared CanvaTemplatesValidator allowlist.
#
# NAMED attachments rather than one bag partitioned by blob metadata — the
# `board_printables.files` lesson in CLAUDE.md: a partition written as an
# exclusion once handed a listing video to a buyer as the product. Here an
# artwork can't be served as a download because `downloads` is a different
# collection, not because a filter remembered.
#
# Artwork is composited in Chrome by the scene engine and is NEVER sent to an
# image model.
#
# Listings (Etsy drafts with a curated gallery) are a follow-up; nothing here
# talks to a marketplace. Details: .claude-notes/printable-products.md
class PrintableProduct < ApplicationRecord
  include AttachedFileUrls

  CATEGORY_DEVICE_TAG = "device_tag".freeze
  # Allowlist. Each category must also be a SceneTemplate::CATEGORIES entry,
  # because a product composites only into scenes of its own category.
  CATEGORIES = [CATEGORY_DEVICE_TAG].freeze

  STATUS_DRAFT = "draft".freeze
  STATUS_READY = "ready".freeze
  STATUS_ARCHIVED = "archived".freeze
  STATUSES = [STATUS_DRAFT, STATUS_READY, STATUS_ARCHIVED].freeze

  SLUG_FORMAT = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

  # What the scene renderer will inline into Chrome — the same allowlist
  # SceneComposition::UPLOAD_CONTENT_TYPES keeps. No SVG (a script container),
  # no HEIC (Chrome can't draw it).
  ARTWORK_CONTENT_TYPES = %w[image/png image/jpeg image/webp].freeze
  # Canva exports a 2x PNG easily past 10 MB; same cap as a scene base image.
  MAX_ARTWORK_BYTES = 25.megabytes
  MAX_ARTWORKS = 20

  DOWNLOAD_CONTENT_TYPES = %w[application/pdf image/png].freeze
  MAX_DOWNLOAD_BYTES = 50.megabytes
  # Etsy's cap on digital files per listing, so a follow-up listing can carry
  # every download without choosing.
  MAX_DOWNLOADS = 5

  MAX_TEMPLATES = 8
  MAX_LABEL_LENGTH = 80

  has_many_attached :artworks
  has_many_attached :downloads

  has_many :scene_compositions, as: :owner, dependent: :destroy

  scope :ordered, -> { order(:name) }
  scope :active, -> { where.not(status: STATUS_ARCHIVED) }

  before_validation :normalize_slug

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true, format: { with: SLUG_FORMAT }
  validates :category, inclusion: { in: CATEGORIES }
  validates :status, inclusion: { in: STATUSES }
  validates :canva_templates, canva_templates: { max: MAX_TEMPLATES }
  validate :attachments_allowed

  def archived? = status == STATUS_ARCHIVED

  def archive!
    update!(status: STATUS_ARCHIVED)
  end

  # The template category this product composites into. A device tag in a board
  # scene would be a picture of the wrong product.
  def scene_template_category = category

  def ordered_artworks
    return [] unless artworks.attached?

    artworks.sort_by { |file| [file.created_at, file.id] }
  end

  def ordered_downloads
    return [] unless downloads.attached?

    downloads.sort_by { |file| [file.created_at, file.id] }
  end

  # The blob ids a scene slot may name as `product_artwork`. Read fresh from the
  # attachments table rather than a loaded association, because the renderer
  # re-asserts it after the composition was saved.
  def artwork_blob_ids
    artworks_attachments.pluck(:blob_id)
  end

  def artwork_label(file) = label_for(file)
  def download_label(file) = label_for(file)

  def usable_canva_templates = CanvaTemplatesValidator.usable(canva_templates)

  # Attaches one design image at a VERSIONED key (CloudFront caches by path and
  # ignores query strings). Type, size and count are checked BEFORE the blob is
  # uploaded, so a refused file leaves nothing in the bucket; the model
  # validation below is the backstop for any other write path.
  def attach_artwork!(io:, filename:, content_type:, label: nil)
    check_upload!(io, content_type, ARTWORK_CONTENT_TYPES, MAX_ARTWORK_BYTES)
    raise ArgumentError, "a product holds at most #{MAX_ARTWORKS} artworks" if ordered_artworks.size >= MAX_ARTWORKS

    attach_or_purge!(artworks, create_blob!(io, filename, content_type, label))
  end

  def attach_download!(io:, filename:, content_type:, label: nil)
    check_upload!(io, content_type, DOWNLOAD_CONTENT_TYPES, MAX_DOWNLOAD_BYTES)
    raise ArgumentError, "a product holds at most #{MAX_DOWNLOADS} downloads" if ordered_downloads.size >= MAX_DOWNLOADS

    attach_or_purge!(downloads, create_blob!(io, filename, content_type, label))
  end

  # Scene compositions whose slots draw this artwork. Removing an artwork in use
  # would leave those mockups unrenderable, so the admin refuses it — the same
  # restrict-don't-cascade rule SceneTemplate keeps.
  def compositions_using_artwork(blob_id)
    scene_compositions.select do |composition|
      composition.slot_art.to_h.values.any? do |entry|
        entry["source"] == SceneComposition::SOURCE_PRODUCT_ARTWORK && entry["blob_id"] == blob_id.to_i
      end
    end
  end

  def versioned_storage_key_for(filename)
    "printable_products/#{id || "new"}/#{SecureRandom.hex(4)}/#{ActiveStorage::Filename.new(filename.to_s).sanitized}"
  end

  private

  def label_for(file)
    file.metadata["label"].presence || File.basename(file.filename.to_s, ".*")
  end

  def check_upload!(io, content_type, allowed, max_bytes)
    unless allowed.include?(content_type.to_s)
      raise ArgumentError, "#{content_type.inspect} is not one of #{allowed.join(", ")}"
    end

    size = io.respond_to?(:size) ? io.size : nil
    raise ArgumentError, "files must be under #{max_bytes / 1.megabyte} MB" if size && size > max_bytes
  end

  # `attach` on a persisted record saves it, so a validation failure returns
  # falsy; the blob it uploaded must not be left behind in the bucket.
  def attach_or_purge!(collection, blob)
    return blob if collection.attach(blob)

    blob.purge
    raise ActiveRecord::RecordInvalid, self
  end

  def create_blob!(io, filename, content_type, label)
    ActiveStorage::Blob.create_and_upload!(
      io: io,
      filename: filename,
      content_type: content_type,
      key: versioned_storage_key_for(filename),
      metadata: { "label" => label.to_s.strip.first(MAX_LABEL_LENGTH).presence }.compact,
    )
  end

  # A slug is derived from the name only when none was given, and a given one is
  # parameterized rather than refused for a stray capital or space.
  def normalize_slug
    source = slug.presence || name
    self.slug = source.to_s.parameterize.presence
  end

  def attachments_allowed
    check_attachments(:artworks, ARTWORK_CONTENT_TYPES, MAX_ARTWORK_BYTES, MAX_ARTWORKS)
    check_attachments(:downloads, DOWNLOAD_CONTENT_TYPES, MAX_DOWNLOAD_BYTES, MAX_DOWNLOADS)
  end

  def check_attachments(name, allowed, max_bytes, max_count)
    files = public_send(name)
    return unless files.attached?

    errors.add(name, "can have at most #{max_count} files") if files.size > max_count

    files.each do |file|
      blob = file.blob
      next unless blob

      unless allowed.include?(blob.content_type)
        errors.add(name, "#{blob.filename} is #{blob.content_type.presence || "an unknown type"}, not one of #{allowed.join(", ")}")
      end
      errors.add(name, "#{blob.filename} is over #{max_bytes / 1.megabyte} MB") if blob.byte_size.to_i > max_bytes
      if blob.metadata["label"].to_s.length > MAX_LABEL_LENGTH
        errors.add(name, "#{blob.filename} has a label over #{MAX_LABEL_LENGTH} characters")
      end
    end
  end
end
