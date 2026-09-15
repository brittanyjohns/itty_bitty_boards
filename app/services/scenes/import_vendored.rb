# Seeds the scene library with the vendored single-quad mockups
# (Boards::Printables::TabletScene / PaperScene), so it isn't empty on day one
# and the multi-slot engine can be checked against scenes whose quads are
# already known to be right.
#
# Idempotent: a template that already exists is left alone — an admin may have
# recalibrated it in the UI, and re-seeding must not quietly revert that.
# `force: true` re-syncs name and slots from the constants (the base image is
# never re-uploaded).
module Scenes
  class ImportVendored
    SLUG_PREFIX = "vendored-".freeze

    Result = Struct.new(:created, :updated, :unchanged, :skipped, keyword_init: true)

    def self.call(**kwargs) = new(**kwargs).call

    def initialize(force: false)
      @force = force
    end

    def call
      result = Result.new(created: [], updated: [], unchanged: [], skipped: [])

      definitions.each do |values|
        slug = "#{SLUG_PREFIX}#{values[:slug]}"
        path = Boards::Printables::MockupScene::DIR.join("#{values[:slug]}.jpg")
        unless File.exist?(path)
          result.skipped << slug
          next
        end

        template = SceneTemplate.find_or_initialize_by(slug: slug)

        if template.new_record?
          create(template, values, path)
          result.created << slug
        elsif force
          template.assign_attributes(name: name_for(values), slots: [slot_for(values)])
          if template.changed?
            template.save!
            result.updated << slug
          else
            result.unchanged << slug
          end
        else
          result.unchanged << slug
        end
      end

      result
    end

    private

    attr_reader :force

    def definitions
      Boards::Printables::TabletScene::SCENES + Boards::Printables::PaperScene::SCENES
    end

    def create(template, values, path)
      template.assign_attributes(
        name: name_for(values),
        category: "board",
        source: "vendored",
        status: SceneTemplate::STATUS_CALIBRATED,
        slots: [slot_for(values)],
        notes: "Imported from Boards::Printables::#{tablet?(values) ? "TabletScene" : "PaperScene"} (#{values[:slug]}).",
      )
      File.open(path, "rb") do |file|
        template.assign_base_image(io: file, filename: "#{values[:slug]}.jpg", content_type: "image/jpeg")
      end

      # The quads were clicked in the JPG's pixels. A photo that isn't the size
      # the constant claims would put every corner somewhere else.
      if [template.width, template.height] != [values[:width], values[:height]]
        raise ArgumentError, "#{values[:slug]}.jpg is #{template.width}x#{template.height}, " \
                             "but its quad was calibrated at #{values[:width]}x#{values[:height]}"
      end

      template.save!
    end

    def tablet?(values) = values[:kind] == Boards::Printables::MockupScene::KIND_TABLET

    def name_for(values) = "#{values[:slug].to_s.titleize} (vendored)"

    def slot_for(values)
      geometry = Boards::Printables::MockupScene.new(values).slot
      orientation = if values[:orientation]
        values[:orientation].to_s
      else
        geometry.quad_landscape? ? "landscape" : "portrait"
      end

      {
        "key" => tablet?(values) ? "screen" : "sheet",
        "label" => tablet?(values) ? "Tablet screen" : "Printed sheet",
        "kind" => values[:kind],
        "quad" => values[:quad],
        "orientation" => orientation,
        "accepts" => tablet?(values) ? %w[device_screen upload] : %w[page_thumbnail upload],
        "finish" => geometry.finish,
        # The vendored quads already sit proud of the glass where they need to.
        "bleed_px" => 0,
      }
    end
  end
end
