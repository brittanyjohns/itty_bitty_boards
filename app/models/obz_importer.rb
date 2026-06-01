# app/services/obz_importer.rb
# frozen_string_literal: true

require "zip"
require "json"
require "stringio"
require "base64"
require "pathname"
require "set"

class ObzImporter
  class ImportError < StandardError; end

  def initialize(file_or_bytes, current_user, board_group: nil, board_id: nil, import_all: true)
    @file_or_bytes = file_or_bytes
    @current_user = current_user
    @board_group = board_group
    if board_group.blank?
      Rails.logger.warn "[ObzImporter] No BoardGroup provided for import"
    end
    @board_id = board_id
    @import_all = import_all

    @entries = {}  # original_path => raw_bytes
    @path_index = {}  # normalized_path => original_path
    @manifest_dir = ""  # directory (normalized) where manifest.json was found
  end

  def import!
    Rails.logger.info "[ObzImporter] Reading ZIP entries from .obz file: #{log_type(@file_or_bytes)}"
    read_zip_entries!(@file_or_bytes)

    manifest = read_manifest # may be nil
    obf_paths = resolve_obf_paths(@entries.keys, manifest)
    raise ImportError, "No .obf files found in .obz" if obf_paths.empty?

    root_obf_path = resolve_root_obf_path(obf_paths, manifest)
    raise ImportError, "Root board could not be determined" unless root_obf_path

    boards_by_obf_id = {}
    obf_id_by_path = {}  # normalized zip path → obf_id, for resolving load_board.path
    dynamic_data_rows = []

    paths_to_import = @import_all ? obf_paths : [root_obf_path]

    paths_to_import.each do |path|
      raw = read_entry(path)
      raise ImportError, "Missing OBF at #{path}" unless raw

      obf_json = parse_json_document(raw, context: path)
      normalize_all_ids!(obf_json)
      inject_inline_data_for_paths!(obf_json)
      if !@board_group && obf_json["board_group"].is_a?(Hash)
        Rails.logger.info "[ObzImporter] Creating new BoardGroup from board_group data in OBF"
        @board_group = BoardGroup.create!(obf_json["board_group"])
      end

      if @board_group && same_norm_path?(path, root_obf_path) && @board_group.original_obf_root_id.blank?
        @board_group.update(original_obf_root_id: obf_json["id"].to_s) rescue nil
      end

      begin
        board, dynamic_data = Board.from_obf(obf_json, @current_user, @board_group, @board_id)
      rescue StandardError => e
        Rails.logger.error "[ObzImporter] Skipping #{path}: #{e.class}: #{e.message}"
        next
      end
      next unless board
      obf_id = obf_json["id"].to_s
      boards_by_obf_id[obf_id] = board
      obf_id_by_path[normalize_zip_path(path)] = obf_id
      dynamic_data_rows.concat(Array(dynamic_data).map { |_, row| row })
    end

    root_board = if @import_all
        root_obf_json = parse_json_document(read_entry(root_obf_path), context: root_obf_path)
        boards_by_obf_id[root_obf_json["id"].to_s]
      else
        boards_by_obf_id.values.first
      end

    if @board_group && root_board && @board_group.root_board_id != root_board.id
      @board_group.update(root_board_id: root_board.id) rescue nil
    end

    link_dynamic_boards!(dynamic_data_rows, boards_by_obf_id, obf_id_by_path, root_board)

    { boards: boards_by_obf_id, root_board: root_board, dynamic_data: dynamic_data_rows }
  rescue ImportError => e
    Rails.logger.error "[ObzImporter] Import error: #{e.message}"
    raise
  rescue => e
    Rails.logger.error "[ObzImporter] Unexpected error: #{e.class}: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    raise ImportError, "Unexpected error importing .obz"
  end

  private

  # --------------------------
  # Post-import linking
  # --------------------------

  # Resolve `load_board` buttons captured by Board.from_obf into actual
  # BoardImage#predictive_board_id links. Per the OBF spec, load_board may
  # use either `id` (id of another OBF in the same package) or `path` (zip
  # entry path). We try id first, then path, then fall back to root_board so
  # navigation never dead-ends on a button the user expects to link somewhere.
  def link_dynamic_boards!(rows, boards_by_obf_id, obf_id_by_path, root_board)
    rows.each do |row|
      dynamic_board = row["dynamic_board"]
      next unless dynamic_board.is_a?(Hash)

      board_image = BoardImage.find_by(id: row["board_image_id"])
      next unless board_image

      target = resolve_link_target(dynamic_board, boards_by_obf_id, obf_id_by_path) || root_board
      next unless target

      board_image.update_columns(predictive_board_id: target.id)
    end
  end

  def resolve_link_target(dynamic_board, boards_by_obf_id, obf_id_by_path)
    if (id_ref = dynamic_board["id"]).present? && (b = boards_by_obf_id[id_ref.to_s])
      return b
    end
    if (path_ref = dynamic_board["path"]).present?
      norm = normalize_zip_path(path_ref)
      obf_id = obf_id_by_path[norm]
      return boards_by_obf_id[obf_id] if obf_id
    end
    nil
  end

  # --------------------------
  # ZIP reading + path index
  # --------------------------

  def log_type(input)
    case input
    when Pathname then "Pathname"
    when IO, StringIO then input.class.name
    when String then "String"
    else input.class.name
    end
  end

  def read_zip_entries!(file_or_bytes)
    bytes = case file_or_bytes
      when Pathname
        File.binread(file_or_bytes.to_s)
      when IO, StringIO
        file_or_bytes.read
      when String
        file_or_bytes
      else
        file_or_bytes.to_s
      end

    bytes = bytes.dup.force_encoding(Encoding::BINARY)

    Zip::File.open_buffer(bytes) do |zip|
      zip.each do |entry|
        next if entry.name_is_directory?
        original = entry.name
        data = entry.get_input_stream.read
        @entries[original] = data
        @path_index[normalize_zip_path(original)] = original
      end
    end
  end

  # Normalize for robust matching
  def normalize_zip_path(path)
    s = path.to_s.tr("\\", "/")
    s = s.gsub(%r{/+}, "/")
    s = s.sub(%r{\A\./}, "")
    s = s.sub(%r{\A/}, "")
    s.downcase
  end

  def same_norm_path?(a, b) = normalize_zip_path(a) == normalize_zip_path(b)

  def read_entry(path)
    Rails.logger.info "[ObzImporter] Reading entry: #{path}"
    data = @entries[path]
    unless data
      # try normalized lookup
      norm = normalize_zip_path(path)
      alt = @path_index[norm]
      data = @entries[alt] if alt
    end
    if data
      Rails.logger.info "[ObzImporter] Entry found for path #{path}, size: #{data.bytesize} bytes"
    else
      Rails.logger.warn "[ObzImporter] Entry not found for path #{path}"
    end
    data
  end

  # --------------------------
  # Manifest / OBF resolution
  # --------------------------

  def read_manifest
    candidates = @entries.keys.select { |k| File.basename(k).downcase == "manifest.json" }
    if candidates.empty?
      Rails.logger.info "[ObzImporter] No manifest.json found (any path)"
      return nil
    end

    preferred = candidates.find { |k| !k.include?("/") } || candidates.first
    raw = read_entry(preferred)
    return nil unless raw

    Rails.logger.info "[ObzImporter] manifest.json bytes: #{raw.bytesize} (from #{preferred})"

    # Remember the manifest directory (normalized)
    @manifest_dir = begin
        dir = File.dirname(preferred)
        dir == "." ? "" : normalize_zip_path(dir) # "" means zip root
      end

    text = ensure_utf8_text(raw)
    manifest = try_parse_json(text)
    raise ImportError, "Invalid manifest.json" unless manifest.is_a?(Hash)
    manifest
  end

  def resolve_obf_paths(all_entry_paths, manifest)
    if manifest
      paths_hash = manifest.dig("paths", "boards") || {}
      listed = paths_hash.values.select { |p| p.to_s.downcase.end_with?(".obf") }.uniq
      # Resolve each manifest path to an actual entry key
      resolved = listed.map { |p| resolve_to_entry_key(p) }.compact.uniq
      Rails.logger.info "[ObzImporter] Manifest lists #{resolved.size} board(s)"
      resolved
    else
      obfs = all_entry_paths.select { |n| n.downcase.end_with?(".obf") }.sort
      Rails.logger.info "[ObzImporter] No manifest.json; found #{obfs.size} .obf file(s)"
      obfs
    end
  end

  def resolve_root_obf_path(obf_paths, manifest)
    return guess_root_obf_path(obf_paths) unless manifest

    root_raw = manifest["root"]
    if root_raw
      resolved = resolve_to_entry_key(root_raw)
      if resolved && obf_paths.any? { |p| same_norm_path?(p, resolved) }
        return resolved
      end
      Rails.logger.warn "[ObzImporter] Manifest root '#{root_raw}' not found among entries; guessing root"
      return guess_root_obf_path(obf_paths)
    end

    Rails.logger.warn "[ObzImporter] Manifest missing root; guessing root"
    guess_root_obf_path(obf_paths)
  end

  # Critical fix: resolve manifest paths relative to manifest directory too.
  def resolve_to_entry_key(path)
    raw = path.to_s
    norm = normalize_zip_path(raw)

    # 1) As-is
    if (orig = @path_index[norm])
      return orig
    end

    # 2) Relative to manifest directory
    if @manifest_dir && !@manifest_dir.empty?
      joined = normalize_zip_path(File.join(@manifest_dir, raw))
      if (orig2 = @path_index[joined])
        return orig2
      end
    end

    Rails.logger.warn "[ObzImporter] Could not resolve path from manifest: #{path}"
    nil
  end

  # Guess root when missing/invalid
  def guess_root_obf_path(obf_paths)
    Rails.logger.info "[ObzImporter] Guessing root .obf (#{obf_paths.size} candidates)"

    preferred_names = %w[root.obf index.obf main.obf home.obf]
    by_name = obf_paths.find { |p| preferred_names.include?(File.basename(p).downcase) }
    return by_name if by_name

    referenced = Set.new
    obf_paths.each do |p|
      json = safe_parse(read_entry(p))
      next unless json
      Array(json["buttons"]).each do |btn|
        ref = btn.dig("load_board", "path")
        next unless ref
        resolved = resolve_to_entry_key(ref)
        referenced << obf_paths.find { |q| same_norm_path?(q, resolved) } if resolved
      end
    end

    candidates = obf_paths.reject { |p| referenced.include?(p) }
    if candidates.any?
      root_level = candidates.select { |p| !p.include?("/") }
      return root_level.min_by(&:length) if root_level.any?
      return candidates.min_by(&:length)
    end

    Rails.logger.warn "[ObzImporter] Could not deduce root; using first alphabetically"
    obf_paths.sort.first
  end

  # --------------------------
  # JSON helpers
  # --------------------------

  def parse_json_document(raw_bytes, context:)
    text = ensure_utf8_text(raw_bytes)
    obj = try_parse_json(text)
    unless obj.is_a?(Hash)
      Rails.logger.error "[ObzImporter] #{context} is not a JSON object"
      raise ImportError, "Invalid JSON in #{context}"
    end
    obj
  end

  def ensure_utf8_text(bytes)
    str = bytes.dup
    str.force_encoding(Encoding::UTF_8)
    unless str.valid_encoding?
      str = bytes.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "")
    end
    str.sub!(/\A\xEF\xBB\xBF/, "") # BOM
    str.delete!("\x00")            # NULs
    str
  end

  def try_parse_json(text)
    JSON.parse(text)
  rescue JSON::ParserError => e
    Rails.logger.error "[ObzImporter] JSON parse error: #{e.class}: #{e.message}"
    compact = text.gsub(/\s+/, " ")
    JSON.parse(compact)
  rescue JSON::ParserError => e2
    Rails.logger.error "[ObzImporter] JSON still invalid after cleanup: #{e2.class}: #{e2.message}"
    nil
  end

  def safe_parse(raw)
    return nil unless raw
    parse_json_document(raw, context: "obf")
  rescue
    nil
  end

  # --------------------------
  # Spec compliance cleanup
  # --------------------------

  def normalize_all_ids!(obf)
    obf["id"] = obf["id"].to_s if obf.key?("id")

    Array(obf["buttons"]).each do |btn|
      btn["id"] = btn["id"].to_s if btn.key?("id")
      btn["image_id"] = btn["image_id"].to_s if btn.key?("image_id")
      btn["sound_id"] = btn["sound_id"].to_s if btn.key?("sound_id")
      if btn["load_board"].is_a?(Hash) && btn["load_board"]["id"]
        btn["load_board"]["id"] = btn["load_board"]["id"].to_s
      end
    end

    Array(obf["images"]).each { |img| img["id"] = img["id"].to_s if img.key?("id") }
    Array(obf["sounds"]).each { |snd| snd["id"] = snd["id"].to_s if snd.key?("id") }

    if obf["grid"].is_a?(Hash) && obf["grid"]["order"].is_a?(Array)
      obf["grid"]["order"] = obf["grid"]["order"].map do |row|
        Array(row).map { |cell| cell.nil? ? nil : cell.to_s }
      end
    end
  end

  # Inline assets referenced via `path`
  def inject_inline_data_for_paths!(obf)
    Array(obf["images"]).each do |img|
      next if img["data"].present?
      path = img["path"].presence
      next unless path

      bytes = read_entry(path)
      unless bytes
        Rails.logger.warn "[ObzImporter] Image path not found in zip: #{path}"
        next
      end
      content_type = img["content_type"].presence || infer_mime_type(path)
      img["content_type"] = content_type if content_type
      img["data"] = Base64.strict_encode64(bytes)
      img.delete("path")
    end

    Array(obf["sounds"]).each do |snd|
      next if snd["data"].present?
      path = snd["path"].presence
      next unless path

      bytes = read_entry(path)
      unless bytes
        Rails.logger.warn "[ObzImporter] Sound path not found in zip: #{path}"
        next
      end
      content_type = snd["content_type"].presence || infer_mime_type(path)
      snd["content_type"] = content_type if content_type
      snd["data"] = Base64.strict_encode64(bytes)
      snd.delete("path")
    end
  end

  def infer_mime_type(path)
    case File.extname(path).downcase
    when ".png" then "image/png"
    when ".jpg", ".jpeg" then "image/jpeg"
    when ".gif" then "image/gif"
    when ".svg" then "image/svg+xml"
    when ".webp" then "image/webp"
    when ".mp3" then "audio/mpeg"
    when ".wav" then "audio/wav"
    when ".m4a" then "audio/mp4"
    else nil
    end
  end
end
