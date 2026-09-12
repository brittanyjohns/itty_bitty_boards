module Boards
  # The authored fringe `.obf` files on disk, parsed ONCE.
  #
  # Boards::TemplateHealth asks two questions of this — "is there authored source
  # for this template" and "does the database row still match it" — and the admin
  # registry builds one health object per template. Globbing and parsing the seed
  # directory per health object is ~22 files x ~22 templates of file reads on a
  # GET, so the controller loads this once and injects it.
  #
  # Read-only. Nothing here touches the database.
  class FringeSources
    Source = Struct.new(
      :path, :relative_path, :category, :core_template, :rows, :columns, :tile_count,
      keyword_init: true,
    ) do
      def grid_label = "#{rows}x#{columns}"
    end

    def self.load = new(Boards::FringeTemplates.seed_files)

    def initialize(paths)
      @sources = Array(paths).filter_map { |path| parse(path) }
    end

    attr_reader :sources

    # The source a DB row should be compared against: the one authored for the
    # row's own variant, or — when the row carries none — the single source for
    # that category, if there is exactly one. With a category authored in both
    # variants and a row that names neither, there is no unambiguous answer and
    # comparing against a guess would report a false drift.
    def for(category, core_template: nil)
      matches = for_category(category)
      return nil if matches.empty?
      return matches.find { |s| s.core_template == core_template.to_s.downcase } if core_template.present?

      matches.size == 1 ? matches.first : nil
    end

    def for_category(category)
      return [] if category.blank?

      @sources.select { |s| s.category.casecmp?(category.to_s.strip) }
    end

    def variants_for(category)
      for_category(category).filter_map(&:core_template).uniq.sort
    end

    def categories = @sources.map(&:category).uniq.sort

    def relative_paths = @sources.map(&:relative_path).sort

    private

    def parse(path)
      data = JSON.parse(File.read(path))
      grid = data["grid"].is_a?(Hash) ? data["grid"] : {}

      Source.new(
        path: path.to_s,
        relative_path: Pathname.new(path.to_s).relative_path_from(Boards::FringeTemplates::SEED_DIR).to_s,
        category: data["name"].to_s,
        core_template: Boards::FringeTemplates.normalize_variant(data[Boards::FringeTemplates::VARIANT_KEY]),
        rows: grid["rows"].to_i,
        columns: grid["columns"].to_i,
        tile_count: Array(data["buttons"]).size,
      )
    rescue JSON::ParserError, Errno::ENOENT => e
      Rails.logger.warn("[Boards::FringeSources] skipping #{path}: #{e.class}: #{e.message}")
      nil
    end
  end
end
