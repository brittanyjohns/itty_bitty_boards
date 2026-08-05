# Repairs AAC tile colors that drifted from their part_of_speech.
#
# `images.bg_color` / `board_images.bg_color` are snapshots taken when the row
# was written, so a part_of_speech corrected later leaves the stored color
# behind (a "social" tile still painted red, etc). This finds those rows and
# repaints them from the category.
#
# It NEVER touches part_of_speech. A board_image whose category differs from its
# Image's is a deliberate per-board override (see Board.apply_obf_part_of_speech)
# — it gets recolored from its own category, not reset to the Image's.
#
#   bin/rails tile_colors:repair                 # dry run, reports only
#   bin/rails tile_colors:repair WRITE=true      # actually writes
#   bin/rails tile_colors:repair SCOPE=board_images LIMIT=500
module TileColorRepair
  BATCH_SIZE = 500
  SAMPLE_SIZE = 10

  module_function

  # Only colors the preset table itself could have produced count as derived.
  # Anything else is an authored color — an OBF button's explicit
  # background_color, or a hand-picked one — and must not be "repaired".
  #
  # Resolved lazily: rake loads every .rake file before the :environment task
  # runs, so app constants aren't autoloadable at file-load time.
  def derived_hexes
    @derived_hexes ||= ::ColorHelper::PRESET_HEX.values.map { |hex| hex.upcase }.to_set.freeze
  end

  def authored?(record)
    return true if record.is_a?(BoardImage) && record.data.is_a?(Hash) && record.data["explicit_bg_color"]
    return false if record.bg_color.blank?

    !derived_hexes.include?(::ColorHelper.to_hex(record.bg_color, default: "").upcase)
  end

  # nil when the row is already correct or must be left alone.
  def repair_for(record)
    return nil if authored?(record)

    pos = record.is_a?(BoardImage) ? record.effective_part_of_speech : record.part_of_speech
    expected = record.background_color_for(pos)
    return nil if expected.blank?

    current = record.bg_color.presence && ::ColorHelper.to_hex(record.bg_color, default: "").upcase
    return nil if current == expected.upcase

    { bg_color: expected, text_color: ::ColorHelper.text_hex_for(expected), pos: pos, was: record.bg_color }
  end

  def sweep(relation, label:, write:, limit: nil, out: $stdout)
    scanned = 0
    repaired = 0
    samples = []

    relation.find_each(batch_size: BATCH_SIZE) do |record|
      break if limit && repaired >= limit
      scanned += 1

      repair = repair_for(record)
      next unless repair

      repaired += 1
      if samples.size < SAMPLE_SIZE
        samples << "  ##{record.id} #{record.label.inspect} #{repair[:pos]}: #{repair[:was].inspect} -> #{repair[:bg_color]}"
      end

      # update_columns: a plain save would re-run Image#ensure_defaults /
      # BoardImage#set_colors and could fight the stored category.
      record.update_columns(bg_color: repair[:bg_color], text_color: repair[:text_color]) if write
    end

    out.puts "#{label}: scanned #{scanned}, #{write ? "repaired" : "would repair"} #{repaired}"
    out.puts samples.join("\n") unless samples.empty?
    repaired
  end
end

namespace :tile_colors do
  desc "Repaint images/board_images whose bg_color disagrees with their part_of_speech (dry run unless WRITE=true)"
  task repair: :environment do
    write = %w[true 1 yes].include?(ENV["WRITE"].to_s.downcase)
    limit = ENV["LIMIT"].presence&.to_i
    scope = ENV["SCOPE"].presence || "all"

    puts write ? "*** WRITING changes ***" : "*** DRY RUN — pass WRITE=true to apply ***"

    total = 0
    if %w[all images].include?(scope)
      total += TileColorRepair.sweep(Image.where.not(part_of_speech: nil),
                                     label: "images", write: write, limit: limit)
    end
    if %w[all board_images].include?(scope)
      total += TileColorRepair.sweep(BoardImage.includes(:image),
                                     label: "board_images", write: write, limit: limit)
    end

    puts "Total: #{total}"
  end
end
