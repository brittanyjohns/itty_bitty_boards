# 4-point perspective solve for the lifestyle-mockup slide.
#
# Maps a flat src_w x src_h rectangle onto an arbitrary convex quad as a CSS
# `matrix3d(...)`, so a real board page can be warped onto the blank screen of a
# photographed tablet instead of being pasted on flat. Pure math, no deps, no
# ImageMagick — the warp happens in Chrome during the Grover render, which is
# the only image pipeline this app has.
#
# Port of speakanyway-printables' src/templates/shared/homography.ts. That repo
# is authoritative for the listings its own pipeline originates; this is
# authoritative for the ones the Rails admin originates. Same rule, and the same
# drift hazard, as Etsy::CopyRules — but this one is fixed math, so a divergence
# here is a bug rather than a decision.
module Boards
  module Printables
    module Homography
      class DegenerateQuadError < StandardError; end

      module_function

      # Solves the 8 unknowns [a,b,c,d,e,f,g,h] of the projective transform
      #
      #   H = | a b c |
      #       | d e f |
      #       | g h 1 |
      #
      # mapping (0,0)->tl, (w,0)->tr, (w,h)->br, (0,h)->bl. Each point pair
      # contributes two rows of the 8x8 linear system:
      #
      #   a*x + b*y + c - g*x*X - h*y*X = X
      #   d*x + e*y + f - g*x*Y - h*y*Y = Y
      #
      # Solved by Gaussian elimination with partial pivoting.
      #
      # quad is [tl, tr, br, bl], each an [x, y] pair, clockwise from top-left.
      def solve(src_w, src_h, quad)
        raise ArgumentError, "invalid src size #{src_w}x#{src_h}" unless src_w.to_f.positive? && src_h.to_f.positive?

        src = [[0, 0], [src_w, 0], [src_w, src_h], [0, src_h]]

        rows = []
        src.each_with_index do |(x, y), i|
          big_x, big_y = quad[i]
          rows << [x, y, 1, 0, 0, 0, -x * big_x, -y * big_x, big_x].map(&:to_f)
          rows << [0, 0, 0, x, y, 1, -x * big_y, -y * big_y, big_y].map(&:to_f)
        end

        8.times do |col|
          pivot = col
          ((col + 1)...8).each { |row| pivot = row if rows[row][col].abs > rows[pivot][col].abs }

          if rows[pivot][col].abs < 1e-12
            raise DegenerateQuadError, "collinear or coincident corners"
          end

          rows[col], rows[pivot] = rows[pivot], rows[col] unless pivot == col

          8.times do |row|
            next if row == col

            factor = rows[row][col] / rows[col][col]
            next if factor.zero?

            (col...9).each { |k| rows[row][k] -= factor * rows[col][k] }
          end
        end

        rows.each_with_index.map { |row, i| row[8] / row[i] }
      end

      # The CSS matrix3d for an element of size src_w x src_h with
      # `transform-origin: 0 0`, warped onto the quad.
      #
      # CSS matrix3d is COLUMN-major, and the projective 3x3 embeds into a 4x4
      # with the z row and column left as identity:
      #
      #   | a b 0 c |
      #   | d e 0 f |
      #   | 0 0 1 0 |
      #   | g h 0 1 |
      def matrix3d(src_w, src_h, quad)
        a, b, c, d, e, f, g, h = solve(src_w, src_h, quad)
        cells = [a, d, 0, g, b, e, 0, h, 0, 0, 1, 0, c, f, 0, 1]

        "matrix3d(#{cells.map { |n| format('%.8g', n) }.join(', ')})"
      end

      # Where a source point lands once warped. Not used by the render — it is
      # what makes the solve testable without standing up Chrome.
      def apply(solution, x, y)
        a, b, c, d, e, f, g, h = solution
        w = (g * x) + (h * y) + 1

        [((a * x) + (b * y) + c) / w, ((d * x) + (e * y) + f) / w]
      end
    end
  end
end
