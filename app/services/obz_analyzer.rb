# app/services/obz_analyzer.rb
# frozen_string_literal: true

require "zip"
require "json"
require "stringio"
require "set"
require "base64"

module ObzAnalyzer
  module_function

  # Public API -----------------------------------------------------------------
  #
  # Analyze an OBZ file and return a structured Hash you can render as JSON.
  #
  # file_or_bytes: Pathname | IO | StringIO | String (raw bytes; never probed as a path)
  #
  # Returns a Hash:
  # {
  #   package: {...},        # package-level overview and checks
  #   manifest: {...},       # manifest presence and resolution results
  #   root_board: {...},     # how root was determined
  #   totals: {...},         # aggregate counts across all boards
  #   boards: [ {...}, ...], # per-board stats
  #   warnings: [ ... ]      # any non-fatal issues
  # }
  #
  def analyze(file_or_bytes)
    # --- Read ZIP into memory (bytes), build path index (normalized) ---
    entries, index = read_zip_to_hash(file_or_bytes) # {orig_path => bytes}, {norm => orig}

    # --- Find manifest anywhere (prefer root-level) ---
    manifest_raw, manifest_path = find_manifest(entries)
    manifest_dir_norm = manifest_path ? normalize_path(File.dirname(manifest_path)) : ""
    manifest = manifest_raw ? parse_json_strict(manifest_raw) : nil

    warnings = []
    manifest_info = {
      found: !!manifest,
      path: manifest_path,
      dir: manifest_dir_norm.to_s == "." ? "" : manifest_dir_norm,
      declared_board_count: manifest ? ((manifest.dig("paths", "boards") || {}).size) : 0,
      unresolved_manifest_board_paths: [],
    }

    # --- Resolve OBF list (manifest-aware), tolerant to relative paths ---
    obf_paths = if manifest
        listed = (manifest.dig("paths", "boards") || {}).values
        resolved = listed.map { |p| resolve_to_zip_entry(p, index, manifest_dir_norm) }
        unresolved = listed.zip(resolved).select { |_p, r| r.nil? }.map(&:first)
        manifest_info[:unresolved_manifest_board_paths] = unresolved
        warnings << "Manifest lists #{unresolved.size} board path(s) that are missing in zip" if unresolved.any?
        resolved.compact.uniq
      else
        entries.keys.select { |k| File.extname(k).downcase == ".obf" }.sort
      end

    if obf_paths.empty?
      return {
               package: package_meta(entries),
               manifest: manifest_info,
               root_board: { resolved: false, method: nil, path: nil },
               totals: empty_totals,
               boards: [],
               warnings: warnings + ["No .obf files found in archive"],
             }
    end

    # --- Determine root board path (manifest root or heuristic) ---
    root_path = if manifest && (root_raw = manifest["root"])
        resolve_to_zip_entry(root_raw, index, manifest_dir_norm) ||
          guess_root_obf_path(obf_paths, entries, index, manifest_dir_norm)
      else
        guess_root_obf_path(obf_paths, entries, index, manifest_dir_norm)
      end

    root_info = {
      resolved: !!root_path,
      method: (manifest && manifest["root"]) ? (root_path ? "manifest.root" : "manifest.root->guess") : "guess",
      manifest_root: manifest && manifest["root"],
      path: root_path,
    }

    # --- Per-board analysis and aggregate stats ---
    aggregate = init_aggregate
    boards = []

    # Graph: which obf paths are referenced by buttons[].load_board.path
    referenced_obf_paths = Set.new

    obf_paths.each do |p|
      raw = entries[p]
      next unless raw
      obj, obj_warnings, non_string_ids = parse_obf_with_checks(raw)
      warnings.concat(obj_warnings.map { |w| "[#{p}] #{w}" }) if obj_warnings.any?

      # Collect referenced load_board paths for root-guess/validation
      Array(obj["buttons"]).each do |btn|
        ref = btn.dig("load_board", "path")
        next unless ref
        resolved = resolve_to_zip_entry(ref, index, manifest_dir_norm)
        referenced_obf_paths << resolved if resolved
      end

      board_stats = per_board_stats(obj)

      # Asset reference modes inside this OBF (how images/sounds are referenced)
      asset_stats = per_board_asset_stats(obj)

      # Merge into aggregate
      merge_aggregate!(aggregate, board_stats, asset_stats, non_string_ids)

      # Missing image/sound references (by id) within this OBF
      missing = find_missing_media_refs(obj)

      boards << {
        path: p,
        id: safe_s(obj["id"]),
        name: safe_s(obj["name"]),
        grid: board_stats[:grid],
        counts: {
          buttons: board_stats[:buttons],
          dynamic_buttons: board_stats[:dynamic_buttons],
          actions_total: board_stats[:actions_total],
          actions_breakdown: board_stats[:actions_breakdown],
          vocalizations: board_stats[:vocalizations],
          absolute_positioned_buttons: board_stats[:absolute_buttons],
        },
        strings_locales: board_stats[:strings_locales],
        license_present: !!obj["license"],
        media: {
          images_defined: asset_stats[:images_defined],
          images_referenced: asset_stats[:images_referenced],
          images_inline_data: asset_stats[:images_inline],
          images_path: asset_stats[:images_path],
          images_url: asset_stats[:images_url],
          images_symbol: asset_stats[:images_symbol],
          image_content_types: asset_stats[:image_content_types].to_a.sort,
          sounds_defined: asset_stats[:sounds_defined],
          sounds_referenced: asset_stats[:sounds_referenced],
          sounds_inline_data: asset_stats[:sounds_inline],
          sounds_path: asset_stats[:sounds_path],
          sounds_url: asset_stats[:sounds_url],
          sound_content_types: asset_stats[:sound_content_types].to_a.sort,
        },
        missing_media_refs: missing,
        non_string_ids_detected: non_string_ids, # true/false
      }
    end

    # Package-level checks: duplicates across package (images/sounds ids in OBZ must be unique)
    pkg_dups = package_level_duplicates(entries, obf_paths)

    # How many boards are referenced from others (dynamic)
    dynamic_targets = obf_paths.select { |p| referenced_obf_paths.include?(p) }
    totals = finalize_totals(aggregate).merge({
      dynamic_target_boards: dynamic_targets.size,
    })

    {
      package: package_meta(entries),
      manifest: manifest_info.merge({
        resolved_board_paths: obf_paths,
        total_boards_listed_or_found: obf_paths.size,
      }),
      root_board: root_info,
      totals: totals,
      boards: boards,
      warnings: warnings + pkg_dups,
    }
  rescue => e
    Rails.logger.error "[ObzAnalyzer] analyze error: #{e.class}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    {
      package: {},
      manifest: { found: false },
      root_board: { resolved: false },
      totals: empty_totals,
      boards: [],
      warnings: ["Analyzer error: #{e.class}: #{e.message}"],
    }
  end

  # Convenience: a quick high-level count (compat with your earlier helper)
  def count_boards(file_or_bytes)
    analyze(file_or_bytes).dig(:manifest, :total_boards_listed_or_found).to_i
  end

  # ----------------------------------------------------------------------------
  # Internal helpers
  # ----------------------------------------------------------------------------

  def read_zip_to_hash(file_or_bytes)
    bytes = case file_or_bytes
      when Pathname
        File.binread(file_or_bytes.to_s)
      when IO, StringIO
        file_or_bytes.read
      when String
        file_or_bytes # treat as raw bytes
      else
        file_or_bytes.to_s
      end
    bytes = bytes.dup.force_encoding(Encoding::BINARY)

    entries = {}
    index = {} # normalized_path => original_path

    Zip::File.open_buffer(bytes) do |zip|
      zip.each do |entry|
        next if entry.name_is_directory?
        orig = entry.name
        data = entry.get_input_stream.read
        entries[orig] = data
        index[normalize_path(orig)] = orig
      end
    end
    [entries, index]
  end

  def find_manifest(entries)
    cands = entries.keys.select { |k| File.basename(k).downcase == "manifest.json" }
    return [nil, nil] if cands.empty?
    preferred = cands.find { |k| !k.include?("/") } || cands.first
    [entries[preferred], preferred]
  end

  def normalize_path(p)
    s = p.to_s.tr("\\", "/")
    s = s.gsub(%r{/+}, "/")
    s = s.sub(%r{\A\./}, "")
    s = s.sub(%r{\A/}, "")
    s.downcase
  end

  def resolve_to_zip_entry(path, index, manifest_dir_norm)
    raw = path.to_s
    # 1) As given
    if (orig = index[normalize_path(raw)])
      return orig
    end
    # 2) Relative to manifest directory
    unless manifest_dir_norm.to_s.empty?
      joined = normalize_path(File.join(manifest_dir_norm, raw))
      if (orig2 = index[joined])
        return orig2
      end
    end
    nil
  end

  def parse_json_strict(bytes)
    str = bytes.dup
    str.force_encoding(Encoding::UTF_8)
    str = bytes.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "") unless str.valid_encoding?
    str.sub!(/\A\xEF\xBB\xBF/, "")
    str.delete!("\x00")
    JSON.parse(str)
  end

  # Guess root: preferred filenames, else unreferenced by others, else top-level, else shortest name, else first alpha
  def guess_root_obf_path(obf_paths, entries, index, manifest_dir_norm)
    preferred = %w[root.obf index.obf main.obf home.obf]
    by_name = obf_paths.find { |p| preferred.include?(File.basename(p).downcase) }
    return by_name if by_name

    # Build set of referenced obf paths via load_board.path
    referenced = Set.new
    obf_paths.each do |p|
      obj = safe_json(entries[p])
      next unless obj.is_a?(Hash)
      Array(obj["buttons"]).each do |btn|
        ref = btn.dig("load_board", "path")
        next unless ref
        resolved = resolve_to_zip_entry(ref, index, manifest_dir_norm)
        referenced << resolved if resolved
      end
    end
    candidates = obf_paths.reject { |p| referenced.include?(p) }
    return candidates.find { |p| !p.include?("/") } || candidates.min_by(&:length) if candidates.any?

    # Fallbacks
    top = obf_paths.find { |p| !p.include?("/") }
    top || obf_paths.min_by(&:length) || obf_paths.sort.first
  end

  def safe_json(bytes)
    parse_json_strict(bytes)
  rescue
    nil
  end

  # --- Per-board analysis -----------------------------------------------------

  def per_board_stats(obj)
    buttons = Array(obj["buttons"])
    images = Array(obj["images"])
    sounds = Array(obj["sounds"])

    dynamic_buttons = buttons.count { |b| b["load_board"].is_a?(Hash) }
    absolute_buttons = buttons.count { |b| %w[left top width height].all? { |k| b.key?(k) } }
    vocalizations = buttons.count { |b| b.key?("vocalization") }

    actions_breakdown = Hash.new(0)
    actions_total = 0
    buttons.each do |b|
      if (a = b["action"])
        actions_total += 1
        actions_breakdown[a] += 1
      end
      Array(b["actions"]).each do |a2|
        actions_total += 1
        actions_breakdown[a2] += 1
      end
    end

    grid = {}
    if obj["grid"].is_a?(Hash)
      grid = {
        rows: obj["grid"]["rows"],
        columns: obj["grid"]["columns"],
        has_order: obj["grid"]["order"].is_a?(Array),
        order_cells: obj.dig("grid", "order")&.flatten&.compact&.size,
      }
    end

    {
      buttons: buttons.size,
      dynamic_buttons: dynamic_buttons,
      absolute_buttons: absolute_buttons,
      vocalizations: vocalizations,
      actions_total: actions_total,
      actions_breakdown: actions_breakdown.sort.to_h,
      grid: grid,
      strings_locales: obj["strings"].is_a?(Hash) ? obj["strings"].keys : [],
    }
  end

  def per_board_asset_stats(obj)
    buttons = Array(obj["buttons"])
    img_defs = Array(obj["images"])
    snd_defs = Array(obj["sounds"])

    # Referenced media ids (from buttons)
    image_refs = buttons.map { |b| b["image_id"] }.compact.map(&:to_s)
    sound_refs = buttons.map { |b| b["sound_id"] }.compact.map(&:to_s)

    # Definition counts by reference mode
    images_inline = img_defs.count { |i| i["data"].is_a?(String) && !i["data"].empty? }
    images_path = img_defs.count { |i| i["path"].is_a?(String) && !i["path"].empty? }
    images_url = img_defs.count { |i| i["url"].is_a?(String) && !i["url"].empty? }
    images_symbol = img_defs.count { |i| i["symbol"].is_a?(Hash) }

    sounds_inline = snd_defs.count { |s| s["data"].is_a?(String) && !s["data"].empty? }
    sounds_path = snd_defs.count { |s| s["path"].is_a?(String) && !s["path"].empty? }
    sounds_url = snd_defs.count { |s| s["url"].is_a?(String) && !s["url"].empty? }

    image_cts = Set.new(img_defs.map { |i| i["content_type"] }.compact.map(&:to_s))
    sound_cts = Set.new(snd_defs.map { |s| s["content_type"] }.compact.map(&:to_s))

    {
      images_defined: img_defs.size,
      images_referenced: image_refs.size,
      images_inline: images_inline,
      images_path: images_path,
      images_url: images_url,
      images_symbol: images_symbol,
      image_content_types: image_cts,

      sounds_defined: snd_defs.size,
      sounds_referenced: sound_refs.size,
      sounds_inline: sounds_inline,
      sounds_path: sounds_path,
      sounds_url: sounds_url,
      sound_content_types: sound_cts,
    }
  end

  def find_missing_media_refs(obj)
    buttons = Array(obj["buttons"])
    img_defs = Array(obj["images"]).map { |i| i["id"].to_s }.to_set
    snd_defs = Array(obj["sounds"]).map { |s| s["id"].to_s }.to_set

    img_refs = buttons.map { |b| b["image_id"] }.compact.map(&:to_s)
    snd_refs = buttons.map { |b| b["sound_id"] }.compact.map(&:to_s)

    {
      images_missing: (img_refs - img_defs.to_a).uniq.sort,
      sounds_missing: (snd_refs - snd_defs.to_a).uniq.sort,
    }
  end

  # Track if non-string ids were detected (contrary to spec) BEFORE normalization
  def parse_obf_with_checks(raw)
    warnings = []
    obj = safe_json(raw)
    return [{}, ["Invalid OBF JSON"], false] unless obj.is_a?(Hash)

    non_string_ids = false

    Array(obj["buttons"]).each do |b|
      non_string_ids ||= b["id"].is_a?(Numeric) || b["image_id"].is_a?(Numeric) || b["sound_id"].is_a?(Numeric)
    end
    Array(obj["images"]).each do |i|
      non_string_ids ||= i["id"].is_a?(Numeric)
    end
    Array(obj["sounds"]).each do |s|
      non_string_ids ||= s["id"].is_a?(Numeric)
    end
    if obj["grid"].is_a?(Hash) && obj["grid"]["order"].is_a?(Array)
      obj["grid"]["order"].each do |row|
        Array(row).each { |cell| non_string_ids ||= cell.is_a?(Numeric) }
      end
    end
    warnings << "Non-string IDs detected (will need normalization)" if non_string_ids

    [obj, warnings, non_string_ids]
  end

  # --- Aggregate totals -------------------------------------------------------

  def init_aggregate
    {
      boards: 0,
      buttons: 0,
      dynamic_buttons: 0,
      absolute_buttons: 0,
      vocalizations: 0,
      actions_total: 0,
      actions_breakdown: Hash.new(0),
      images_defined: 0,
      images_referenced: 0,
      images_inline: 0,
      images_path: 0,
      images_url: 0,
      images_symbol: 0,
      image_content_types: Set.new,
      sounds_defined: 0,
      sounds_referenced: 0,
      sounds_inline: 0,
      sounds_path: 0,
      sounds_url: 0,
      sound_content_types: Set.new,
      non_string_ids_boards: 0,
    }
  end

  def merge_aggregate!(agg, board_stats, asset_stats, non_string_ids)
    agg[:boards] += 1
    agg[:buttons] += board_stats[:buttons]
    agg[:dynamic_buttons] += board_stats[:dynamic_buttons]
    agg[:absolute_buttons] += board_stats[:absolute_buttons]
    agg[:vocalizations] += board_stats[:vocalizations]
    agg[:actions_total] += board_stats[:actions_total]
    board_stats[:actions_breakdown].each { |k, v| agg[:actions_breakdown][k] += v }

    agg[:images_defined] += asset_stats[:images_defined]
    agg[:images_referenced] += asset_stats[:images_referenced]
    agg[:images_inline] += asset_stats[:images_inline]
    agg[:images_path] += asset_stats[:images_path]
    agg[:images_url] += asset_stats[:images_url]
    agg[:images_symbol] += asset_stats[:images_symbol]
    agg[:image_content_types].merge(asset_stats[:image_content_types])

    agg[:sounds_defined] += asset_stats[:sounds_defined]
    agg[:sounds_referenced] += asset_stats[:sounds_referenced]
    agg[:sounds_inline] += asset_stats[:sounds_inline]
    agg[:sounds_path] += asset_stats[:sounds_path]
    agg[:sounds_url] += asset_stats[:sounds_url]
    agg[:sound_content_types].merge(asset_stats[:sound_content_types])

    agg[:non_string_ids_boards] += 1 if non_string_ids
  end

  def finalize_totals(agg)
    agg.dup.tap do |h|
      h[:image_content_types] = h[:image_content_types].to_a.sort
      h[:sound_content_types] = h[:sound_content_types].to_a.sort
      h[:actions_breakdown] = h[:actions_breakdown].sort.to_h
    end
  end

  def empty_totals
    finalize_totals(init_aggregate)
  end

  # --- Package level checks ---------------------------------------------------

  def package_meta(entries)
    {
      zip_entries: entries.size,
      total_bytes: entries.values.map(&:bytesize).sum,
    }
  end

  # In OBZ packages, image/sound IDs are expected to be unique across the package.
  # This detects duplicate IDs across *all* OBFs (not within a single OBF).
  def package_level_duplicates(entries, obf_paths)
    img_ids = Hash.new(0)
    snd_ids = Hash.new(0)
    warnings = []

    obf_paths.each do |p|
      obj = safe_json(entries[p])
      next unless obj.is_a?(Hash)
      Array(obj["images"]).each { |i| img_ids[i["id"].to_s] += 1 if i["id"] }
      Array(obj["sounds"]).each { |s| snd_ids[s["id"].to_s] += 1 if s["id"] }
    end

    dup_imgs = img_ids.select { |_k, v| v > 1 }.keys
    dup_snds = snd_ids.select { |_k, v| v > 1 }.keys

    warnings << "Duplicate image IDs across package: #{dup_imgs.join(", ")}" if dup_imgs.any?
    warnings << "Duplicate sound IDs across package: #{dup_snds.join(", ")}" if dup_snds.any?
    warnings
  end

  # --- Utils ------------------------------------------------------------------

  def safe_s(v)
    v.is_a?(String) ? v : v.to_s
  end
end
