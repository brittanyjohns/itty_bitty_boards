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

  # A 360x60 text box along the bottom of a 400x300 base.
  def scene_text_slot(key: "headline", box: [20, 210, 360, 60], **overrides)
    {
      "key" => key,
      "label" => key.humanize,
      "box" => box,
      "rotation" => 0,
      "font" => "fredoka",
      "weight" => 600,
      "color" => "#17385c",
      "align" => "center",
      "max_px" => 48,
      "min_px" => 16,
      "max_chars" => 60,
      "default" => "Printable AAC",
    }.merge(overrides.transform_keys(&:to_s))
  end

  def scene_overlay(key: "facts", partial: "feature_list", box: [200, 20, 180, 170])
    { "key" => key, "partial" => partial, "box" => box }
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

  # A device-tag product with `artwork_count` labelled PNG designs.
  def create_printable_product(artwork_count: 0, **attrs)
    product = PrintableProduct.create!({ name: "Device Tags #{SecureRandom.hex(3)}", size_label: "2.5 x 2 in" }.merge(attrs))
    artwork_count.times do |index|
      product.attach_artwork!(
        io: StringIO.new(scene_png(250, 200, ChunkyPNG::Color.rgb(40 * index, 120, 200))),
        filename: "tag-#{index + 1}.png",
        content_type: "image/png",
        label: "Voice Tag #{index + 1}",
      )
    end
    product
  end

  # Two landscape tag slots side by side in a 400x300 base.
  def device_tag_slots
    [
      scene_slot(key: "tag_a", kind: "tag", accepts: %w[product_artwork upload], quad: [[20, 60], [190, 60], [190, 200], [20, 200]]),
      scene_slot(key: "tag_b", kind: "tag", accepts: %w[product_artwork upload], quad: [[210, 60], [380, 60], [380, 200], [210, 200]]),
    ]
  end

  def create_device_tag_template(**kwargs)
    create_scene_template(category: "device_tag", slots: device_tag_slots, **kwargs)
  end

  def uploaded_scene_png(width = 400, height = 300, filename: "scene.png", content_type: "image/png")
    Rack::Test::UploadedFile.new(StringIO.new(scene_png(width, height)), content_type, original_filename: filename)
  end
end

RSpec.configure do |config|
  config.include SceneTemplateHelpers
end
