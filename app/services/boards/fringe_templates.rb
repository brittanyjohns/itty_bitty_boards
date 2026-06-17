module Boards
  module FringeTemplates
    SEED_DIR = Rails.root.join("db/seeds/board_builder_sets/fringe-pages")
    TEMPLATE_MARKER = "fringe_template_category"

    module_function

    def find(category_name)
      return nil if category_name.blank?

      Board.where(user_id: admin_id)
        .where("LOWER(settings->>'#{TEMPLATE_MARKER}') = ?", category_name.to_s.strip.downcase)
        .first
    end

    def all_templates
      Board.where(user_id: admin_id)
        .where("settings->>'#{TEMPLATE_MARKER}' IS NOT NULL")
        .order(:name)
    end

    def seed_all!
      return [] unless SEED_DIR.exist?

      results = []
      Dir.glob(SEED_DIR.join("*.obf")).sort.each do |path|
        results << seed_obf!(path)
      end
      results.compact
    end

    def seed_obf!(path)
      obf_data = JSON.parse(File.read(path))
      category = obf_data["name"]
      obf_id = obf_data["id"]

      admin_user = User.find_by(id: admin_id)
      raise "Admin user (#{admin_id}) not found" unless admin_user

      board = Board.from_obf(
        obf_data, nil, admin_user,
        import_options: {
          apply_button_attributes: true,
        },
      )
      return nil unless board

      board.update!(
        predefined: true,
        published: true,
        settings: (board.settings || {}).merge(
          TEMPLATE_MARKER => category.downcase,
          "disable_scroll" => true,
        ),
      )

      prune_removed_tiles!(board, obf_data)
      board
    end

    def prune_removed_tiles!(board, obf_data)
      keep = Array(obf_data["buttons"]).map { |b| b["label"].to_s.strip.downcase }
      board.board_images.includes(:image).find_each do |bi|
        label = (bi.image&.label || bi.label).to_s.strip.downcase
        bi.destroy unless keep.include?(label)
      end
    end

    def admin_id
      User::DEFAULT_ADMIN_ID
    end
  end # module FringeTemplates
end
