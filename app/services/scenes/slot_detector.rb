module Scenes
  # Finds the magenta placeholder surfaces in a marked scene and fits each one
  # with the four corners a SceneTemplate slot needs.
  #
  # 1. Label connected magenta regions on a STRIDE-sampled grid (scanline
  #    union-find, 4-connected), which is what keeps a 1536x1024 scene affordable
  #    in Ruby.
  # 2. Drop anything under MIN_AREA_RATIO of the image: a speck of pink in a
  #    kid's shirt is not a slot.
  # 3. Back at FULL resolution, inside each region's bounding box, take the
  #    leftmost and rightmost magenta pixel edge of every row.
  # 4. Convex hull (monotone chain). The hull is what fills the notch an
  #    occluder leaves in an edge — a clip over the top of a sheet still gives
  #    the sheet's own corners. The occluder itself goes in the front layer.
  # 5. Reduce the hull to 4 vertices, one least-area change at a time (see
  #    #reduce_to_four for why that collapses edges rather than deleting
  #    vertices).
  # 6. Order the corners TL, TR, BR, BL — clockwise in image coordinates, the
  #    shape SceneSlot#clockwise_convex? demands.
  #
  # Coordinates are PIXEL EDGES in the base image's space (a rectangle of pixels
  # 40..159 spans 40..160), matching how a slot is calibrated by hand.
  class SlotDetector
    DEFAULT_STRIDE = 2
    MIN_AREA_RATIO = 0.005
    # Detected quads sit a hair inside the magenta (the 4-vertex fit is
    # inscribed in the hull), so the art is pushed out a few pixels. The front
    # layer clips the art back to exactly where the magenta was.
    DETECTED_BLEED_PX = 3

    Region = Struct.new(:root, :count, :min_gx, :min_gy, :max_gx, :max_gy, keyword_init: true)

    attr_reader :mask, :stride, :regions

    def initialize(image, stride: DEFAULT_STRIDE, min_area_ratio: MIN_AREA_RATIO, category: "board", mask: nil)
      @image = image
      @mask = mask || MagentaMask.new(image)
      @stride = [stride.to_i, 1].max
      @min_area_ratio = min_area_ratio
      @category = category.to_s
      @regions = []
    end

    # => [slot hash, ...] in SceneTemplate's normalized slot shape, reading
    # order (top to bottom, then left to right).
    def call
      quads.each_with_index.map { |quad, index| slot_hash(quad, index + 1) }
    end

    # => [[[x, y] × 4], ...]. Also fills #regions with each kept component's
    # full-resolution bounding box [x0, y0, x1, y1] (inclusive).
    def quads
      @quads ||= begin
        labels = label_grid
        found = kept_regions(labels).filter_map do |region|
          points = boundary_points(region, labels)
          next if points.size < 3

          quad = order_clockwise_from_top_left(reduce_to_four(convex_hull(points)))
          next unless quad && Boards::Printables::SceneSlot.new(quad: quad).clockwise_convex?

          @regions << pixel_bbox(region)
          quad
        end
        order = found.each_index.sort_by { |i| [centroid(found[i])[1].round, centroid(found[i])[0]] }
        @regions = order.map { |i| @regions[i] }
        order.map { |i| found[i] }
      end
    end

    private

    def width = @image.width
    def height = @image.height
    def grid_w = @grid_w ||= (width + stride - 1) / stride
    def grid_h = @grid_h ||= (height + stride - 1) / stride

    # Grid cell → resolved component root (0 = not magenta).
    def label_grid
      labels = Array.new(grid_w * grid_h, 0)
      @parent = [0]

      grid_h.times do |gy|
        y = gy * stride
        row = gy * grid_w
        grid_w.times do |gx|
          next unless mask.magenta_at?(gx * stride, y)

          i = row + gx
          left = gx.positive? ? labels[i - 1] : 0
          up = gy.positive? ? labels[i - grid_w] : 0

          labels[i] =
            if left.zero? && up.zero?
              @parent << @parent.size
              @parent.size - 1
            elsif left.zero?
              up
            elsif up.zero?
              left
            else
              union(left, up)
            end
        end
      end

      labels.map! { |label| label.zero? ? 0 : find(label) }
    end

    def find(label)
      root = label
      root = @parent[root] while @parent[root] != root
      while @parent[label] != root
        next_label = @parent[label]
        @parent[label] = root
        label = next_label
      end
      root
    end

    def union(a, b)
      ra = find(a)
      rb = find(b)
      return ra if ra == rb

      ra < rb ? (@parent[rb] = ra) : (@parent[ra] = rb)
      [ra, rb].min
    end

    def kept_regions(labels)
      by_root = {}
      labels.each_with_index do |root, i|
        next if root.zero?

        gx = i % grid_w
        gy = i / grid_w
        region = by_root[root] ||= Region.new(root: root, count: 0, min_gx: gx, min_gy: gy, max_gx: gx, max_gy: gy)
        region.count += 1
        region.min_gx = gx if gx < region.min_gx
        region.max_gx = gx if gx > region.max_gx
        region.min_gy = gy if gy < region.min_gy
        region.max_gy = gy if gy > region.max_gy
      end

      min_cells = (@min_area_ratio * width * height) / (stride * stride)
      by_root.values.select { |region| region.count >= min_cells }
    end

    # Leftmost/rightmost magenta pixel of every row in the region's box, as
    # pixel-edge points. A full-resolution pixel belongs to the region when any
    # of the four grid samples around it does, which keeps two regions whose
    # boxes overlap from borrowing each other's pixels.
    def boundary_points(region, labels)
      x0, y0, x1, y1 = pixel_bbox(region)
      points = []

      (y0..y1).each do |y|
        left = (x0..x1).find { |x| member?(x, y, region.root, labels) }
        next unless left

        right = x1.downto(left).find { |x| member?(x, y, region.root, labels) }
        points << [left, y] << [left, y + 1] << [right + 1, y] << [right + 1, y + 1]
      end

      points.uniq
    end

    def member?(x, y, root, labels)
      return false unless mask.magenta_at?(x, y)

      gx = x / stride
      gy = y / stride
      [[gx, gy], [gx + 1, gy], [gx, gy + 1], [gx + 1, gy + 1]].any? do |cx, cy|
        cx < grid_w && cy < grid_h && labels[(cy * grid_w) + cx] == root
      end
    end

    def pixel_bbox(region)
      [
        [(region.min_gx * stride) - stride, 0].max,
        [(region.min_gy * stride) - stride, 0].max,
        [(region.max_gx * stride) + stride, width - 1].min,
        [(region.max_gy * stride) + stride, height - 1].min,
      ]
    end

    # Andrew's monotone chain. Keeps strictly left turns, so collinear points
    # are dropped and the result turns the way SceneSlot's cross product calls
    # clockwise in image coordinates.
    def convex_hull(points)
      sorted = points.sort
      return sorted if sorted.size < 3

      lower = []
      sorted.each do |pt|
        lower.pop while lower.size >= 2 && cross(lower[-2], lower[-1], pt) <= 0
        lower << pt
      end
      upper = []
      sorted.reverse_each do |pt|
        upper.pop while upper.size >= 2 && cross(upper[-2], upper[-1], pt) <= 0
        upper << pt
      end
      lower[0...-1] + upper[0...-1]
    end

    # Reduces the hull to 4 vertices one step at a time, each step changing the
    # area as little as possible.
    #
    # The preferred step COLLAPSES an edge: its two neighbouring edges are
    # extended until they meet, which adds a sliver of area and removes a
    # vertex. Simply deleting the vertex whose triangle is smallest rounds the
    # real corners off: the pixel staircase leaves a short chamfer at each
    # corner, and a true corner flanked by two close hull points has the
    # smallest triangle of all (a skewed 70px screen came out 4px short). The
    # collapse restores the corner instead, and the quad encloses the magenta.
    # Vertex deletion remains the fallback when no edge can collapse (its
    # neighbours are parallel or diverge).
    def reduce_to_four(hull)
      poly = hull.map { |x, y| [x.to_f, y.to_f] }
      return nil if poly.size < 4

      while poly.size > 4
        n = poly.size
        collapse = (0...n).filter_map { |i| edge_collapse(poly, i) }.min_by(&:last)

        if collapse
          index, point, = collapse
          poly[index] = point
          poly.delete_at((index + 1) % n)
        else
          cheapest = (0...n).min_by { |i| triangle_area(poly[(i - 1) % n], poly[i], poly[(i + 1) % n]) }
          poly.delete_at(cheapest)
        end
      end
      poly.map { |x, y| [x.round.clamp(0, width), y.round.clamp(0, height)] }
    end

    # Collapsing edge i (poly[i] → poly[i+1]): where the edge before it and the
    # edge after it meet, and the area that adds. nil when they don't meet
    # beyond both ends.
    def edge_collapse(poly, i)
      n = poly.size
      a0 = poly[(i - 1) % n]
      a1 = poly[i]
      b1 = poly[(i + 1) % n]
      b0 = poly[(i + 2) % n]

      d1 = [a1[0] - a0[0], a1[1] - a0[1]]
      d2 = [b1[0] - b0[0], b1[1] - b0[1]]
      denom = (d1[0] * d2[1]) - (d1[1] * d2[0])
      return nil if denom.abs < 1e-9

      diff = [b0[0] - a0[0], b0[1] - a0[1]]
      t = ((diff[0] * d2[1]) - (diff[1] * d2[0])) / denom
      u = ((diff[0] * d1[1]) - (diff[1] * d1[0])) / denom
      return nil unless t >= 1.0 && u >= 1.0

      point = [a0[0] + (t * d1[0]), a0[1] + (t * d1[1])]
      [i, point, triangle_area(a1, point, b1)]
    end

    # The top edge is the one whose midpoint sits highest; its start is TL. On a
    # tie (a diamond) the edge starting further left wins.
    def order_clockwise_from_top_left(quad)
      return nil unless quad&.size == 4

      quad = quad.reverse if signed_area(quad).negative?
      top = (0...4).min_by do |i|
        a = quad[i]
        b = quad[(i + 1) % 4]
        [((a[1] + b[1]) / 2.0).round, a[0]]
      end
      quad.rotate(top).map { |x, y| [x.round, y.round] }
    end

    def slot_hash(quad, number)
      aspect = Boards::Printables::SceneSlot.new(quad: quad).aspect.to_f
      orientation = if aspect > 1.05 then "landscape"
                    elsif aspect < 0.95 then "portrait"
                    else "any"
                    end
      kind = if @category == "device_tag" then "tag"
             elsif aspect > 1.1 then "tablet"
             else "paper"
             end

      SceneTemplate.normalize_slot(
        "key" => "slot#{number}",
        "label" => "Slot #{number}",
        "kind" => kind,
        "quad" => quad,
        "orientation" => orientation,
        "bleed_px" => DETECTED_BLEED_PX,
      )
    end

    def cross(o, a, b) = ((a[0] - o[0]) * (b[1] - o[1])) - ((a[1] - o[1]) * (b[0] - o[0]))
    def triangle_area(a, b, c) = cross(a, b, c).abs / 2.0

    # Positive when the turn is clockwise on screen (y down).
    def signed_area(poly)
      poly.each_index.sum do |i|
        a = poly[i]
        b = poly[(i + 1) % poly.size]
        (a[0] * b[1]) - (b[0] * a[1])
      end
    end

    def centroid(quad) = [quad.sum { |x, _| x } / 4.0, quad.sum { |_, y| y } / 4.0]
  end
end
