module Images
  # Finds duplicate LIBRARY images and picks a survivor for each group.
  #
  # PURE READ. This class writes nothing, ever — it is the "preview" half of the
  # dedupe, mirroring the rail Admin::BoardBuildsController documents for the
  # board builder. Callers persist the result as an ImageMergeBatch plan and a
  # human reviews it before anything is destroyed. Note in particular that it
  # resolves survivors WITHOUT going through Boards::ImageResolver.resolve,
  # which creates a blank Image row for an unmatched label.
  #
  # Scope: never a user's image. The candidate set is Image.default_public
  # (`user_id IN [nil, DEFAULT_ADMIN_ID]`, not private), minus the image types
  # that are not library symbols at all. Menu items are per-restaurant, scenario
  # and sample-voice rows are machinery — none of them are "the same word twice".
  #
  # Grouping is (normalized label, language, part_of_speech), and all three
  # matter:
  #   * label     — the matching key; `images.label` is already lowercased by
  #                 Image#set_label, but historical rows predate that.
  #   * language  — "dog" (en) and "dog" (es) are different words.
  #   * part_of_speech — Images::PromptBuilder disambiguates homographs by it,
  #                 so "can" the verb and "can" the noun are DIFFERENT PICTURES
  #                 by design and must never be collapsed into one.
  class DuplicateScanner
    # Types that aren't interchangeable library symbols.
    EXCLUDED_IMAGE_TYPES = %w[menu Menu SampleVoice OpenaiPrompt Scenario].freeze

    def self.call(...) = new(...).call

    # @param label [String, nil] restrict to one label (for a targeted run)
    # @param limit [Integer, nil] cap the number of GROUPS returned
    def initialize(label: nil, limit: nil)
      @label = label.presence
      @limit = limit
    end

    # @return [Hash] { groups: [...], report: {...} } — the ImageMergeBatch plan
    def call
      groups = duplicate_keys.filter_map { |key| build_group(key) }
      groups = groups.first(@limit) if @limit

      { "groups" => groups, "report" => report_for(groups) }
    end

    # The candidate set. Public so the merge job can re-assert membership at
    # execution time against exactly the same definition.
    def self.candidate_scope
      Image.default_public.where(
        "images.image_type IS NULL OR images.image_type NOT IN (?)", EXCLUDED_IMAGE_TYPES
      )
    end

    # The grouping key for one image, as the scanner computes it. Shared with
    # the merge job so "has this row drifted since the scan?" is one definition.
    def self.group_key_for(image)
      [
        Image.normalize_label(image.label),
        image.language.presence || "en",
        image.part_of_speech.presence || "-",
      ]
    end

    private

    def base_scope
      scope = self.class.candidate_scope
      scope = scope.where("LOWER(TRIM(images.label)) = ?", Image.normalize_label(@label)) if @label
      scope
    end

    # Group keys with more than one row. Done in SQL so the whole library
    # doesn't have to be instantiated.
    def duplicate_keys
      base_scope
        .group(grouping_sql)
        .having("COUNT(*) > 1")
        .order(Arel.sql("COUNT(*) DESC"))
        .count
        .keys
        .map { |key| Array(key) }
    end

    def grouping_sql
      [
        Arel.sql("LOWER(TRIM(images.label))"),
        Arel.sql("COALESCE(images.language, 'en')"),
        Arel.sql("COALESCE(images.part_of_speech, '-')"),
      ]
    end

    def images_for(key)
      label, language, pos = key
      scope = base_scope.where("LOWER(TRIM(images.label)) = ?", label)
      scope = scope.where("COALESCE(images.language, 'en') = ?", language)
      scope.where("COALESCE(images.part_of_speech, '-') = ?", pos)
    end

    def build_group(key)
      images = images_for(key).left_joins(:docs)
                              .group("images.id")
                              .select("images.id, COUNT(docs.id) AS doc_count")
                              .to_a
      return nil if images.size < 2

      # Survivor: most docs, tie-broken by lowest id. Deliberately the same
      # ordering as Boards::ImageResolver.best_arted, which is already this
      # codebase's answer to "which Image is canonical for this label" — the
      # dedupe should feed that rule, not compete with it. When no row in the
      # group has art at all, lowest id wins (it is the most referenced).
      ordered = images.sort_by { |i| [-i.doc_count.to_i, i.id] }
      survivor = ordered.first

      {
        "key" => key,
        "survivor_id" => survivor.id,
        "loser_ids" => ordered.drop(1).map(&:id),
        "doc_counts" => ordered.to_h { |i| [i.id.to_s, i.doc_count.to_i] },
      }
    end

    # Broken out because the three states need different remedies: merging only
    # helps a group where SOME row has art.
    def report_for(groups)
      with_art = 0
      all_blank = 0
      mixed = 0

      groups.each do |group|
        counts = group["doc_counts"].values
        arted = counts.count(&:positive?)
        if arted.zero?
          all_blank += 1
        elsif arted == counts.size
          with_art += 1
        else
          mixed += 1
        end
      end

      {
        "groups" => groups.size,
        "redundant_rows" => groups.sum { |g| g["loser_ids"].size },
        "mixed_art_groups" => mixed,
        "all_have_art_groups" => with_art,
        "all_blank_groups" => all_blank,
      }
    end
  end
end
