# Builders for the scene engine's specs (SceneTemplate / SceneComposition).
# Real PNG bytes, because SceneTemplate reads an upload's pixel size with
# libvips rather than trusting a number from the form.
module SceneTemplateHelpers
  def scene_png(width = 400, height = 300, color = ChunkyPNG::Color::WHITE)
    ChunkyPNG::Image.new(width, height, color).to_blob
  end

  # A 120x160 portrait quad inside a 400x300 base, clockwise from top-left.
  def scene_slot(key: "fridge", quad: [[40, 40], [160, 40], [160, 200], [40, 200]], **overrides)
    {
      "key" => key,
      "label" => key.humanize,
      "kind" => "paper",
      "quad" => quad,
      "orientation" => "any",
      "accepts" => %w[page_thumbnail device_screen upload],
      "finish" => "shadow",
      "bleed_px" => 0,
    }.merge(overrides.transform_keys(&:to_s))
  end

  def build_scene_template(slots: [scene_slot], width: 400, height: 300, front_layer: false, **attrs)
    template = SceneTemplate.new(
      {
        slug: "scene-#{SecureRandom.hex(4)}",
        name: "Test scene",
        category: "board",
        source: "canva",
        status: SceneTemplate::STATUS_CALIBRATED,
        slots: slots,
      }.merge(attrs),
    )
    template.assign_base_image(io: StringIO.new(scene_png(width, height)), filename: "base.png", content_type: "image/png")
    if front_layer
      template.assign_front_layer(
        io: StringIO.new(scene_png(width, height, ChunkyPNG::Color::TRANSPARENT)),
        filename: "front.png",
        content_type: "image/png",
      )
    end
    template
  end

  def create_scene_template(**kwargs)
    build_scene_template(**kwargs).tap(&:save!)
  end

  def uploaded_scene_png(width = 400, height = 300, filename: "scene.png", content_type: "image/png")
    Rack::Test::UploadedFile.new(StringIO.new(scene_png(width, height)), content_type, original_filename: filename)
  end
end

RSpec.configure do |config|
  config.include SceneTemplateHelpers
end
