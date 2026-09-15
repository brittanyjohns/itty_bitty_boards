# One SceneTemplate filled with one product's real art — the admin's pick, per
# slot, of what gets warped into each placeholder.
#
# `slot_art` is keyed by the template's slot keys. Each entry names an ART
# SOURCE, and every source is something this app RENDERS or an admin uploaded;
# none of them is ever produced by, or sent to, an image model:
#
#   page_thumbnail — {"source", "board_id", "ink" => color|low_ink, "header" => bool}
#                    the printed page, via RenderPageThumbnails
#   device_screen  — {"source", "board_id"}
#                    the board inside the app chrome, via RenderDeviceScreen
#   upload         — {"source", "blob_id"}
#                    a picture attached to THIS composition's slot_uploads
#
# A slot with no entry renders the base image untouched.
#
# The owner is polymorphic because device tags (#957) reuse the engine; today it
# is always a BoardPrintable, and a board_id must be one of its board_ids.
#
# Details: .claude-notes/scene-engine.md
class SceneComposition < ApplicationRecord
  include AttachedFileUrls

  # Bump when the composition template or its CSS changes what a render looks
  # like: it feeds the digest, so every existing render reads stale.
  # 2: text slots and fact overlays drawn above the front layer (#955).
  RENDER_SPEC_VERSION = 2

  SOURCE_PAGE_THUMBNAIL = "page_thumbnail".freeze
  SOURCE_DEVICE_SCREEN = "device_screen".freeze
  SOURCE_UPLOAD = "upload".freeze
  SOURCES = [SOURCE_PAGE_THUMBNAIL, SOURCE_DEVICE_SCREEN, SOURCE_UPLOAD].freeze
  BOARD_SOURCES = [SOURCE_PAGE_THUMBNAIL, SOURCE_DEVICE_SCREEN].freeze

  INK_COLOR = "color".freeze
  INK_LOW = "low_ink".freeze
  INKS = [INK_COLOR, INK_LOW].freeze

  UPLOAD_CONTENT_TYPES = %w[image/png image/jpeg image/webp].freeze
  MAX_UPLOAD_BYTES = 10.megabytes

  # Which template category an owner may composite into. A board printable in a
  # device-tag scene would be a picture of the wrong product.
  CATEGORY_FOR_OWNER = { "BoardPrintable" => "board" }.freeze

  belongs_to :owner, polymorphic: true
  belongs_to :scene_template
  belongs_to :board_printable_listing, optional: true

  has_many_attached :slot_uploads
  has_one_attached :render

  scope :recent, -> { order(created_at: :desc) }

  before_validation :normalize_slot_art
  before_validation :normalize_text_values

  validate :template_usable, on: :create
  validate :slot_art_valid
  validate :text_values_valid
  validate :listing_belongs_to_owner

  # One slot_art entry, normalized. nil means "leave this slot empty".
  def self.normalize_entry(raw)
    h = raw.to_h.transform_keys(&:to_s)
    source = h["source"].to_s.strip

    case source
    when ""
      nil
    when SOURCE_PAGE_THUMBNAIL
      {
        "source" => source,
        "board_id" => integer_or_nil(h["board_id"]),
        "ink" => h["ink"].to_s.presence || INK_COLOR,
        "header" => h.key?("header") ? ActiveModel::Type::Boolean.new.cast(h["header"]) == true : true,
      }
    when SOURCE_DEVICE_SCREEN
      { "source" => source, "board_id" => integer_or_nil(h["board_id"]) }
    when SOURCE_UPLOAD
      { "source" => source, "blob_id" => integer_or_nil(h["blob_id"]) }
    else
      # Kept so validation can name it, rather than silently emptying the slot.
      { "source" => source }
    end
  end

  def self.integer_or_nil(value)
    str = value.to_s.strip
    str.match?(/\A\d+\z/) ? str.to_i : nil
  end

  # The boards this composition may render. A printable that walked no tree
  # still has its root.
  def owner_board_ids
    ids = Array(owner.try(:board_ids)).map(&:to_i)
    ids.presence || Array(owner.try(:board_id)).compact.map(&:to_i)
  end

  def referenced_board_ids
    slot_art.to_h.values.filter_map { |entry| entry["board_id"] if BOARD_SOURCES.include?(entry["source"]) }.uniq
  end

  def upload_blob_ids
    slot_uploads.map(&:blob_id).compact
  end

  def filled_slot_keys = slot_art.to_h.keys

  # The words a text slot renders: this composition's own, or the slot's
  # default when it left the field blank. "" means the slot draws nothing.
  def resolved_text(text_slot)
    text_values.to_h[text_slot["key"]].presence || text_slot["default"].to_s
  end

  # The facts an overlay region renders from, narrowed to the listing when the
  # composition is for one. nil for an owner GalleryFacts can't describe.
  def overlay_facts
    return nil unless owner.is_a?(BoardPrintable)

    @overlay_facts ||= ::Printables::GalleryFacts.new(owner, listing: board_printable_listing)
  end

  # SHA of everything a render is a picture of: the template and the version of
  # its calibration, every slot's art choice, the words in each text slot, the
  # facts an overlay quotes, and the updated_at of each board a slot draws. A
  # change to any of them makes the attached render stale.
  #
  # Board updated_at is a proxy — a tile edit that doesn't touch the board row
  # won't move it — the same trade the listing gallery makes.
  def current_render_digest
    boards = Board.where(id: referenced_board_ids).order(:id).pluck(:id, :updated_at)
                  .map { |id, at| [id, at&.utc&.iso8601(6)] }
    art = slot_art.to_h.sort.map { |key, entry| [key, entry.to_h.sort.to_h] }
    texts = text_values.to_h.sort
    facts = Array(scene_template&.overlay_regions).any? ? overlay_facts&.digest : nil

    Digest::SHA256.hexdigest(
      [RENDER_SPEC_VERSION, scene_template_id, scene_template&.calibration_version, art, boards, texts, facts].to_json,
    )
  end

  def stale?
    !render.attached? || render_digest != current_render_digest
  end

  def render_url
    render.attached? ? url_for_file(render) : nil
  end

  def versioned_storage_key_for(filename)
    "scene_compositions/#{id || "new"}/#{SecureRandom.hex(4)}/#{ActiveStorage::Filename.new(filename.to_s).sanitized}"
  end

  # Content type and size are re-checked here rather than trusted from the
  # caller: the allowlist is an invariant of what the renderer will inline into
  # Chrome, not one controller remembering to ask.
  def attach_slot_upload!(io:, filename:, content_type:)
    unless UPLOAD_CONTENT_TYPES.include?(content_type.to_s)
      raise ArgumentError, "#{content_type.inspect} is not one of #{UPLOAD_CONTENT_TYPES.join(", ")}"
    end

    size = io.respond_to?(:size) ? io.size : nil
    raise ArgumentError, "uploads must be under #{MAX_UPLOAD_BYTES / 1.megabyte} MB" if size && size > MAX_UPLOAD_BYTES

    blob = ActiveStorage::Blob.create_and_upload!(
      io: io,
      filename: filename,
      content_type: content_type,
      key: versioned_storage_key_for(filename),
    )
    slot_uploads.attach(blob)
    blob
  end

  # Purges uploads no slot points at any more — switching a slot to a page
  # render shouldn't leave its old picture in the bucket forever.
  def prune_unused_uploads!
    in_use = slot_art.to_h.values.filter_map { |entry| entry["blob_id"] if entry["source"] == SOURCE_UPLOAD }
    slot_uploads.reject { |upload| in_use.include?(upload.blob_id) }.each(&:purge)
    slot_uploads.reset
  end

  # Stamps the render with the digest computed BEFORE rendering, so an edit made
  # while Chrome was busy still reads as stale. update_columns rather than
  # update!: a board removed from the printable since must not make a finished
  # render impossible to record.
  def attach_render!(bytes:, digest:)
    filename = "scene-#{id}.jpg"
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(bytes),
      filename: filename,
      content_type: "image/jpeg",
      key: versioned_storage_key_for(filename),
    )
    render.attach(blob)
    update_columns(render_digest: digest, rendered_at: Time.current, error: nil)
    blob
  end

  # Queued after the surrounding transaction commits (a no-op outside one), so
  # the worker can never dequeue before the row it names exists.
  def enqueue_render!
    composition_id = id
    ActiveRecord.after_all_transactions_commit { RenderSceneCompositionJob.perform_async(composition_id) }
  end

  private

  def normalize_slot_art
    raw = slot_art.is_a?(Hash) ? slot_art : {}
    self.slot_art = raw.each_with_object({}) do |(key, entry), out|
      normalized = self.class.normalize_entry(entry)
      out[key.to_s] = normalized if normalized
    end
  end

  # Blank means "use the slot's default", so a blank value isn't stored at all.
  # Whitespace is squished: a text slot is one run of words, and a stray
  # newline pasted into the field would otherwise defeat the fit.
  def normalize_text_values
    raw = text_values.is_a?(Hash) ? text_values : {}
    self.text_values = raw.each_with_object({}) do |(key, value), out|
      words = value.to_s.squish
      out[key.to_s] = words if words.present?
    end
  end

  def text_values_valid
    return unless scene_template

    text_values.each do |key, value|
      slot = scene_template.text_slot_for(key)
      unless slot
        errors.add(:text_values, "names a text slot this template doesn't have (#{key})")
        next
      end

      max = slot["max_chars"].to_i
      next if value.length <= max

      errors.add(:text_values, "#{slot["label"].presence || key}: #{value.length} characters is over the #{max}-character limit")
    end
  end

  def template_usable
    return unless scene_template

    errors.add(:scene_template, "must be calibrated before it can be used") unless scene_template.calibrated?

    expected = CATEGORY_FOR_OWNER[owner_type]
    if expected && scene_template.category != expected
      errors.add(:scene_template, "is a #{scene_template.category} scene, not a #{expected} scene")
    end
  end

  def listing_belongs_to_owner
    return unless board_printable_listing
    return if owner_type == "BoardPrintable" && board_printable_listing.board_printable_id == owner_id

    errors.add(:board_printable_listing, "belongs to a different printable")
  end

  def slot_art_valid
    return unless scene_template

    allowed_boards = owner_board_ids
    uploads = upload_blob_ids

    slot_art.each do |key, entry|
      slot = scene_template.slot_for(key)
      unless slot
        errors.add(:slot_art, "names a slot this template doesn't have (#{key})")
        next
      end

      name = slot.label.presence || key
      source = entry["source"]
      unless SOURCES.include?(source)
        errors.add(:slot_art, "#{name}: unknown art source #{source.inspect}")
        next
      end
      errors.add(:slot_art, "#{name}: this slot doesn't take #{source.humanize.downcase}") unless slot.accepts.include?(source)

      case source
      when SOURCE_PAGE_THUMBNAIL, SOURCE_DEVICE_SCREEN
        unless allowed_boards.include?(entry["board_id"])
          errors.add(:slot_art, "#{name}: pick a board from this printable")
        end
        if source == SOURCE_PAGE_THUMBNAIL && !INKS.include?(entry["ink"])
          errors.add(:slot_art, "#{name}: ink must be #{INKS.join(" or ")}")
        end
      when SOURCE_UPLOAD
        errors.add(:slot_art, "#{name}: upload a picture for this slot") unless uploads.include?(entry["blob_id"])
      end
    end
  end
end
