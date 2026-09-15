# Synthetic magenta-marked scenes for the AI scene / slot detection specs.
# Tiny and built in code, so the geometry every assertion checks is written
# down right next to it.
module MagentaSceneHelpers
  SCENE_BG = ChunkyPNG::Color.rgb(216, 200, 168)
  CLIP_GREY = ChunkyPNG::Color.rgb(90, 90, 96)
  MAGENTA = ChunkyPNG::Color.rgb(255, 0, 255)

  # Portrait sheet, pixels 20..79 × 20..109 → edge quad below.
  SHEET_QUAD = [[20, 20], [80, 20], [80, 110], [20, 110]].freeze
  # A grey clip over the sheet's top edge: pixels 45..54 × 14..29.
  CLIP_BOX = [45, 14, 54, 29].freeze
  # A skewed landscape "screen", clockwise from top-left, shaded left to right.
  SCREEN_QUAD = [[110, 40], [180, 30], [186, 92], [114, 100]].freeze

  def inside_convex?(quad, px, py)
    4.times.all? do |i|
      ax, ay = quad[i]
      bx, by = quad[(i + 1) % 4]
      ((bx - ax) * (py - ay)) - ((by - ay) * (px - ax)) >= 0
    end
  end

  def fill_quad(image, quad)
    xs = quad.map(&:first)
    ys = quad.map(&:last)
    (ys.min.floor..ys.max.ceil).each do |y|
      (xs.min.floor..xs.max.ceil).each do |x|
        next unless x.between?(0, image.width - 1) && y.between?(0, image.height - 1)
        next unless inside_convex?(quad, x + 0.5, y + 0.5)

        image.set_pixel(x, y, yield(x, y))
      end
    end
  end

  # 200x150: the clipped portrait sheet, the shaded skewed screen, and a 3x3
  # speck of magenta that must not become a slot.
  def magenta_scene
    image = ChunkyPNG::Image.new(200, 150, SCENE_BG)
    fill_quad(image, SHEET_QUAD) { MAGENTA }
    fill_quad(image, SCREEN_QUAD) do |x, _y|
      level = (255 - ((x - 110) * 1.6)).round.clamp(110, 255)
      ChunkyPNG::Color.rgb(level, 0, level)
    end
    x0, y0, x1, y1 = CLIP_BOX
    (y0..y1).each { |y| (x0..x1).each { |x| image.set_pixel(x, y, CLIP_GREY) } }
    (140..142).each { |y| (190..192).each { |x| image.set_pixel(x, y, MAGENTA) } }
    image
  end

  def magenta_scene_png = magenta_scene.to_blob

  def expect_quad_near(actual, expected, tolerance: 3)
    expect(actual.size).to eq(4)
    actual.zip(expected).each do |(ax, ay), (ex, ey)|
      expect((ax - ex).abs).to be <= tolerance, "expected #{actual.inspect} to be near #{expected.inspect}"
      expect((ay - ey).abs).to be <= tolerance, "expected #{actual.inspect} to be near #{expected.inspect}"
    end
  end
end

RSpec.configure do |config|
  config.include MagentaSceneHelpers
end
