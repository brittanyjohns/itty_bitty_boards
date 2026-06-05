# app/services/vocab_sets.rb
#
# Seeds the Board Builder's "robust vocabulary set" templates (Core 60, Core 84)
# from the authored OBF/OBZ source in db/seeds/board_builder_sets/<slug>/.
#
# Each set is imported via ObzImporter as admin (User::DEFAULT_ADMIN_ID) into a
# linked tree of predefined/published boards. NO BoardGroup is created — the set
# is identified by a marker on its ROOT board (Boards::RobustSets). The Board
# Builder then clones the chosen set per user and routes the child's interests
# into the cloned fringe pages.
#
# Driven by lib/tasks/vocab_sets.rake (vocab_sets:seed / vocab_sets:build).
require "zip"

module VocabSets
  SETS_DIR = Rails.root.join("db", "seeds", "board_builder_sets")

  module_function

  # Slugs that have authored source (a manifest.json), optionally filtered by a
  # comma-separated list.
  def available_slugs(filter = nil)
    present = Dir.children(SETS_DIR).select do |name|
      File.file?(SETS_DIR.join(name, "manifest.json"))
    end.sort
    return present if filter.blank?

    wanted = filter.split(",").map(&:strip)
    present & wanted
  end

  # Zip the authored source dir into in-memory .obz bytes (manifest.json +
  # boards/*.obf), preserving relative paths.
  def obz_bytes(slug)
    dir = SETS_DIR.join(slug)
    raise "No source dir for slug #{slug.inspect} at #{dir}" unless File.directory?(dir)

    buffer = Zip::OutputStream.write_buffer do |zos|
      Dir.glob(dir.join("**", "*")).sort.each do |path|
        next unless File.file?(path)

        rel = Pathname.new(path).relative_path_from(Pathname.new(dir)).to_s
        zos.put_next_entry(rel)
        zos.write(File.binread(path))
      end
    end
    buffer.rewind
    buffer.read
  end

  def admin
    User.find_by(id: User::DEFAULT_ADMIN_ID) ||
      raise("Admin user (User::DEFAULT_ADMIN_ID=#{User::DEFAULT_ADMIN_ID}) not found — seed it first")
  end

  # Import one slug and stamp the result. Idempotent: Board.from_obf upserts by
  # (user_id, obf_id), so re-running updates the same boards. Returns the root.
  def seed_slug!(slug)
    result = ObzImporter.new(
      obz_bytes(slug),
      admin,
      board_group: nil, # root-board-only — no BoardGroup
      import_options: {
        include_images: true, # our own art; copyright gate is for third-party .obz
        license_acknowledged: true,
        acknowledged_by_user_id: admin.id,
      },
    ).import!

    root = result[:root_board]
    raise "Import produced no root board for #{slug.inspect}" unless root

    result[:boards].values.each do |board|
      board.update!(predefined: true, published: true)
    end
    Boards::RobustSets.mark_root!(root, slug)

    root
  end
end
