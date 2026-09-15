# A scene in the shared mockup library: a blank base photo, an optional
# transparent front layer (rings, clips, a hand, glare) that sits ABOVE the art,
# and N calibrated slots — quads real product art is warped into.
#
# Designed in Canva (source: canva), imported from the vendored single-quad
# scenes (source: vendored, `rake scenes:import_vendored`), or — later — AI
# generated (#956). Whatever the source, the ART that goes into a slot is always
# RENDERED and composited in Chrome; it is never sent to an image model.
#
# `calibration_version` is bumped whenever what a slot would render onto
# changes (the slots, or either layer), and it feeds every composition's
# render digest, so a recalibrated template marks its renders stale.
#
# Details: .claude-notes/scene-engine.md
class SceneTemplate < ApplicationRecord
  CATEGORIES = %w[board device_tag].freeze
  SOURCES = %w[canva ai vendored].freeze
  STATUS_DRAFT = "draft".freeze
  STATUS_CALIBRATED = "calibrated".freeze
  STATUS_ARCHIVED = "archived".freeze
  STATUSES = [STATUS_DRAFT, STATUS_CALIBRATED, STATUS_ARCHIVED].freeze

  # An allowlist, the same rule KitPage::IMAGE_CONTENT_TYPES keeps: a picker
  # will hand over an SVG or a HEIC, and neither is something Chrome should be
  # asked to composite from our CDN.
  IMAGE_CONTENT_TYPES = %w[image/png image/jpeg image/webp].freeze
  # Canva exports a full-bleed PNG at 2x easily past 10 MB.
  MAX_IMAGE_BYTES = 25.megabytes
  MAX_SLOTS = 8

  SLUG_FORMAT = /\A[a-z0-9][a-z0-9-]{0,79}\z/
  SLOT_KEY_FORMAT = /\A[a-z0-9_-]{1,40}\z/

  has_one_attached :base_image
  has_one_attached :front_layer

  # restrict, never cascade: a composition's render is a picture of THIS
  # template. Retiring a template in use is `archive!`, which keeps it
  # renderable for the compositions that already point at it.
  has_many :scene_compositions, dependent: :restrict_with_error

  scope :ordered, -> { order(:name) }
  scope :calibrated, -> { where(status: STATUS_CALIBRATED) }
  scope :for_category, ->(category) { where(category: category) }

  before_validation :normalize_slots
  before_save :bump_calibration_version

  validates :slug, presence: true, uniqueness: true, format: { with: SLUG_FORMAT }
  validates :name, presence: true
  validates :category, inclusion: { in: CATEGORIES }
  validates :source, inclusion: { in: SOURCES }
  validates :status, inclusion: { in: STATUSES }
  validates :width, :height, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :base_image_present
  validate :slots_are_valid
  validate :calibrated_needs_slots

  def draft? = status == STATUS_DRAFT
  def calibrated? = status == STATUS_CALIBRATED
  def archived? = status == STATUS_ARCHIVED

  def slot_objects
    Array(slots).map { |slot| Boards::Printables::SceneSlot.from_hash(slot) }
  end

  def slot_for(key)
    slot_objects.find { |slot| slot.key == key.to_s }
  end

  def aspect
    return nil unless width.to_i.positive? && height.to_i.positive?

    width.to_f / height
  end

  def in_use? = scene_compositions.exists?

  def archive!
    update!(status: STATUS_ARCHIVED)
  end

  # Destroys an unused template; archives one that compositions still render.
  # => :destroyed or :archived
  def retire!
    return :archived.tap { archive! } if in_use?

    destroy!
    :destroyed
  end

  # Assigns an uploaded base image and reads its pixel size, which is the space
  # every quad is measured in. Nothing is uploaded until the record saves, so a
  # template that fails validation leaves no orphan blob behind.
  def assign_base_image(io:, filename:, content_type:)
    bytes = read_image!(io, content_type)
    self.width, self.height = self.class.image_dimensions(bytes)
    base_image.attach(attachable_for(bytes, filename, content_type))
  end

  def assign_front_layer(io:, filename:, content_type:)
    bytes = read_image!(io, content_type)
    front_w, front_h = self.class.image_dimensions(bytes)
    @front_layer_size = [front_w, front_h]
    @layers_changed = true
    front_layer.attach(attachable_for(bytes, filename, content_type))
  end

  # [width, height] of an image's bytes. libvips reads only the header here.
  # Required lazily, the way KitPages::DocumentPreviewRenderer does: the gem
  # isn't loaded until something asks for it.
  def self.image_dimensions(bytes)
    require "vips"
    image = Vips::Image.new_from_buffer(bytes, "", access: :sequential)
    [image.width, image.height]
  end

  def self.versioned_storage_key_for(filename)
    "scene_templates/#{SecureRandom.hex(8)}/#{ActiveStorage::Filename.new(filename.to_s).sanitized}"
  end

  # Normalizes one slot hash into the stored shape. Unknown keys are dropped:
  # the slots column is read by the renderer, and a key nothing validates is a
  # key nothing guarantees.
  def self.normalize_slot(raw)
    h = raw.to_h.transform_keys(&:to_s)
    kind = h["kind"].to_s.presence || "paper"
    accepts = Array(h["accepts"]).map(&:to_s).reject(&:blank?).uniq

    {
      "key" => h["key"].to_s.strip,
      "label" => h["label"].to_s.strip.presence || h["key"].to_s.strip.humanize,
      "kind" => kind,
      "quad" => Array(h["quad"]).map { |pt| Array(pt).map { |n| number_or_nil(n) } },
      "orientation" => h["orientation"].to_s.presence || "any",
      "accepts" => accepts.presence || Boards::Printables::SceneSlot::ACCEPTS.dup,
      "finish" => h["finish"].to_s.presence || Boards::Printables::SceneSlot::DEFAULT_FINISH_BY_KIND[kind],
      "bleed_px" => number_or_nil(h["bleed_px"]) || 0,
    }
  end

  def self.number_or_nil(value)
    return value if value.is_a?(Integer)
    return (value.to_f == value.to_f.round ? value.to_i : value.to_f.round(2)) if value.is_a?(Float)

    str = value.to_s.strip
    return nil unless str.match?(/\A-?\d+(\.\d+)?\z/)

    number_or_nil(str.include?(".") ? str.to_f : str.to_i)
  end

  private

  def read_image!(io, content_type)
    unless IMAGE_CONTENT_TYPES.include?(content_type.to_s)
      raise ArgumentError, "#{content_type.inspect} is not one of #{IMAGE_CONTENT_TYPES.join(", ")}"
    end

    bytes = io.read
    io.rewind if io.respond_to?(:rewind)
    raise ArgumentError, "image is larger than #{MAX_IMAGE_BYTES / 1.megabyte} MB" if bytes.bytesize > MAX_IMAGE_BYTES

    bytes
  end

  def attachable_for(bytes, filename, content_type)
    {
      io: StringIO.new(bytes),
      filename: filename,
      content_type: content_type,
      key: self.class.versioned_storage_key_for(filename),
    }
  end

  def normalize_slots
    self.slots = Array(slots).map { |slot| self.class.normalize_slot(slot) }
  end

  def bump_calibration_version
    return if new_record?

    layer_change = @layers_changed || attachment_changes.key?("base_image") || attachment_changes.key?("front_layer")
    return unless slots_changed? || layer_change

    self.calibration_version = calibration_version.to_i + 1
    @layers_changed = false
  end

  def base_image_present
    errors.add(:base_image, "must be uploaded") unless base_image.attached?
  end

  def calibrated_needs_slots
    return unless calibrated?

    errors.add(:status, "can't be calibrated without at least one slot") if Array(slots).empty?
  end

  def slots_are_valid
    list = Array(slots)
    errors.add(:slots, "can have at most #{MAX_SLOTS} slots") if list.size > MAX_SLOTS

    keys = list.map { |slot| slot["key"] }
    dupes = keys.select { |key| keys.count(key) > 1 }.uniq
    errors.add(:slots, "have duplicate keys: #{dupes.join(", ")}") if dupes.any?

    if @front_layer_size && width && height && @front_layer_size != [width, height]
      errors.add(:front_layer, "is #{@front_layer_size.join("x")} but the base image is #{width}x#{height}; export both at the same size")
    end

    list.each_with_index { |slot, index| validate_slot(slot, index) }
  end

  def validate_slot(slot, index)
    name = slot["key"].presence || "##{index + 1}"
    add = ->(message) { errors.add(:slots, "slot #{name}: #{message}") }

    add.call("key must be lowercase letters, digits, - or _") unless slot["key"].to_s.match?(SLOT_KEY_FORMAT)
    add.call("kind must be one of #{Boards::Printables::SceneSlot::KINDS.join(", ")}") unless Boards::Printables::SceneSlot::KINDS.include?(slot["kind"])
    add.call("orientation must be one of #{Boards::Printables::SceneSlot::ORIENTATIONS.join(", ")}") unless Boards::Printables::SceneSlot::ORIENTATIONS.include?(slot["orientation"])
    add.call("finish must be one of #{Boards::Printables::SceneSlot::FINISHES.join(", ")}") unless Boards::Printables::SceneSlot::FINISHES.include?(slot["finish"])

    unknown = Array(slot["accepts"]) - Boards::Printables::SceneSlot::ACCEPTS
    add.call("accepts unknown art sources: #{unknown.join(", ")}") if unknown.any?

    bleed = slot["bleed_px"]
    unless bleed.is_a?(Numeric) && bleed >= 0 && bleed <= Boards::Printables::SceneSlot::MAX_BLEED_PX
      add.call("bleed_px must be between 0 and #{Boards::Printables::SceneSlot::MAX_BLEED_PX}")
    end

    quad = slot["quad"]
    unless quad.is_a?(Array) && quad.size == 4 && quad.all? { |pt| pt.is_a?(Array) && pt.size == 2 && pt.all?(Numeric) }
      add.call("quad must be four [x, y] points, clockwise from top-left")
      return
    end

    if width && height && !quad.all? { |x, y| x.between?(0, width) && y.between?(0, height) }
      add.call("every corner must be inside the #{width}x#{height} base image")
    end

    geometry = Boards::Printables::SceneSlot.from_hash(slot)
    if geometry.degenerate?
      add.call("corners are collinear or coincident")
      return
    end
    add.call("corners must be clockwise from top-left and form a convex shape") unless geometry.clockwise_convex?

    # A homography maps ANY rectangle onto the quad, so a slot filed under the
    # wrong orientation doesn't fail — it's a filter that lies, and the art it
    # admits lands letterboxed to a sliver.
    case slot["orientation"]
    when "portrait"
      add.call("quad is wider than it is tall, so it can't be portrait") if geometry.quad_landscape?
    when "landscape"
      add.call("quad is taller than it is wide, so it can't be landscape") unless geometry.quad_landscape?
    end
  end
end
