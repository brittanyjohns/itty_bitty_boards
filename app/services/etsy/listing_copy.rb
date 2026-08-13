# frozen_string_literal: true

# Builds the default marketplace listing copy for a BoardPrintable — title,
# summary, description, tags, price — from the board it was generated from.
#
# Deterministic and offline on purpose. The equivalent copy in
# speakanyway-printables is generated the same way (templates, not an LLM), so
# a listing reads identically whether it came from the Node pipeline or from
# here, and regenerating it never surprises anyone with new prose.
#
# The output is only ever a DEFAULT: it is written into
# `board_printables.listing_copy` and then edited by hand in the admin UI
# before publishing. Nothing here should be treated as final copy.
module Etsy
  class ListingCopy
    # The product this maps to in the printables pipeline's taxonomy. Every
    # BoardPrintable is an `existing_board` — a real SpeakAnyWay board turned
    # into a printable — so the pools below are that type's, not a generic set.
    PRODUCT_HUMAN = "vocabulary board".freeze

    ALWAYS_ON_TAGS = ["aac", "printable", "digital download"].freeze
    PRODUCT_TYPE_TAGS = ["vocabulary board"].freeze

    # Every printable here genuinely serves all three audiences, so all three
    # contribute tags and all three are named in the description.
    AUDIENCE_TAGS = ["autism support", "slp", "classroom"].freeze
    AUDIENCE_LINES = [
      "Parents and caregivers using AAC at home.",
      "Speech-language pathologists running structured sessions.",
      "Classroom teachers and aides supporting AAC users.",
    ].freeze

    # Fills whatever slots the always-on / product-type / audience / topic tags
    # leave empty, highest buyer intent first. Without these a typical board
    # listed with 6 of a possible 13 tags. Note "voice output aac" is 16 chars —
    # the more natural "talking communication board" is 26 and would be silently
    # dropped by normalize_tag.
    TOP_UP_TAGS = [
      "aac printable",
      "communication board",
      "voice output aac",
      "speech therapy",
      "special education",
      "nonspeaking",
      "slp resources",
      "visual supports",
      "autism printable",
      "classroom visuals",
      "aac board",
    ].freeze

    SUMMARY_MAX = 150

    # What the printables pipeline actually writes into listing.md frontmatter.
    # Note the product-type module in that repo declares `default_price: 4.00`
    # and config/pricing.json declares its own — neither is what ships. 500 is.
    DEFAULT_PRICE_CENTS = 500

    # Prose says "free audio companion", matching the gallery slides
    # (Printables::SlideCopy) and Printables::IncludedItems — a buyer reads the
    # images and the description together and shouldn't meet two names for the
    # same thing. The TAG pool below deliberately keeps "voice output aac":
    # tags are what buyers type into Etsy search, not our voice.
    LEAD = "Give every voice a way to be heard with this Printable Vocabulary Board from " \
           "SpeakAnyWay. Instant digital download. Print at home or open on any device — and " \
           "scan the included QR code to use the same board live in the free SpeakAnyWay app " \
           "with a free audio companion — tap any word and it speaks out loud. No sign-in required.".freeze

    FOOTER = "Pairs with the SpeakAnyWay app at app.speakanyway.com — scan the QR code on any " \
             "board to open the live version with its free audio companion — every word speaks " \
             "out loud when tapped, no sign-in.".freeze

    def initialize(printable)
      @printable = printable
    end

    def build
      {
        "title" => title,
        "summary" => summary,
        "description" => description,
        "tags" => tags,
        "price_cents" => DEFAULT_PRICE_CENTS,
      }
    end

    private

    attr_reader :printable

    def board = printable.board

    def board_name = board&.name.presence || "Board ##{printable.board_id}"

    def topic = printable.topic.presence

    def board_count = [printable.board_ids.to_a.size, 1].max

    def set? = board_count > 1

    # Keyword-forward title. Leads with the board's own name (buyers search
    # "core words board", not "SpeakAnyWay"), then the product type, then the
    # bundle size, then the two highest-volume qualifiers in this niche.
    def title
      @title ||= begin
        base = CopyRules.title_case_words(board_name)

        # When the board's own name already names the product ("Core Words
        # Board"), repeating "Vocabulary Board" reads badly AND eats the
        # 140-char budget, so the type decoration shrinks to "AAC Printable".
        type_words = PRODUCT_HUMAN.downcase.split(/\s+/).select { |w| w.length > 3 }
        names_product = type_words.any? { |w| base.downcase.include?(w) }
        head = names_product ? "#{base} AAC Printable" : "#{base} AAC Vocabulary Board Printable"

        tail = "for Speech Therapy & Autism"
        size_phrase = set? ? "#{board_count}-Board Set" : nil
        topic_phrase = CopyRules.distinct_topic_phrase(
          title: base, topic: topic, product_human: PRODUCT_HUMAN,
        )

        # Widest first, shedding a piece at a time. `base` must stay last: it
        # is the rung guaranteed to fit, and without it a long board name
        # overflows every rung and gets truncated mid-word.
        composed = CopyRules.pick_fitting_title([
          "#{head}, #{[size_phrase, topic_phrase].compact.join(' — ')} #{tail}",
          "#{head}, #{topic_phrase} #{tail}",
          "#{head}, #{size_phrase} #{tail}",
          "#{head} #{tail}",
          "#{head}, #{topic_phrase}",
          head,
          base,
        ])

        CopyRules.ensure_digital_download_suffix(CopyRules.enforce_title_rules(composed))
      end
    end

    def summary
      raw = if topic
        "#{CopyRules.title_case_words(board_name)} — words for #{topic}."
      elsif set?
        "#{CopyRules.title_case_words(board_name)} — a set of #{board_count} printable communication boards."
      else
        "#{CopyRules.title_case_words(board_name)} — a printable communication board you can use today."
      end

      return raw if raw.length <= SUMMARY_MAX

      "#{raw[0, SUMMARY_MAX - 1].rstrip}…"
    end

    def tags
      CopyRules.assemble_tags(
        always_on: ALWAYS_ON_TAGS,
        product_type: PRODUCT_TYPE_TAGS,
        audience: AUDIENCE_TAGS,
        topic: CopyRules.topic_tags(topic),
        top_up: TOP_UP_TAGS,
      )
    end

    # Plain text, not markdown: Etsy renders no markup at all, and TPT's editor
    # takes a paste of plain text cleanly. The printables pipeline emits
    # markdown and converts it at publish time; skipping that round trip means
    # what an admin reads in the textarea is exactly what a buyer sees.
    def description
      sections = [LEAD, "", summary, "", included_section]
      sections += ["", boards_section] if boards_section
      sections += ["", audience_section, "", how_it_works_section, "", ways_to_use_section,
                   "", instant_download_section, "", FOOTER]
      sections.join("\n")
    end

    def included_section
      items = Printables::IncludedItems.all(board_count: board_count, page_count: printable.board_page_count)

      ["WHAT'S INCLUDED", "", *items.map { |i| "- #{i}" }].join("\n")
    end

    # Name the individual boards in a bundle. A page count tells a buyer
    # nothing; "People, Feelings, Food, Play…" is most of the reason to buy.
    def boards_section
      return @boards_section if defined?(@boards_section)

      @boards_section = begin
        labels = board_labels
        if labels.size > 1
          ["THE #{labels.size} BOARDS", "", *labels.map { |l| "- #{l}" }].join("\n")
        end
      end
    end

    # board_ids is in tree order (root first) and a `where` loses that, so the
    # names are re-sorted back into it.
    def board_labels
      ids = printable.board_ids.to_a
      return [] if ids.size <= 1

      names = Board.where(id: ids).pluck(:id, :name).to_h
      ids.filter_map { |id| names[id].presence }
         .map { |n| CopyRules.title_case_words(n) }
         .uniq
    end

    def audience_section
      ["WHO IT'S FOR", "", *AUDIENCE_LINES.map { |l| "- #{l}" }].join("\n")
    end

    def how_it_works_section
      boards = set? ? "boards open" : "board opens"
      [
        "HOW IT WORKS",
        "",
        "1. Download — instant PDF, nothing ships.",
        "2. Print or tap — print at home, or open the file on any tablet, phone, or Chromebook.",
        "3. Scan the QR code — the same #{boards} in the free SpeakAnyWay app, where every " \
        "word is tappable and spoken out loud. The audio companion is included free — no app " \
        "install, no sign-in, no subscription.",
      ].join("\n")
    end

    def ways_to_use_section
      main = set? ? "main board" : "board"
      [
        "WAYS TO USE IT",
        "",
        "- Laminate the #{main} for the fridge, a binder, or the table.",
        "- Print the low-ink version for backups, take-home copies, and whole-class sets.",
        "- Print the trim-ready version when you're cutting and laminating — no header to " \
        "trim off, and the QR code still opens the talking version.",
        "- Send a copy home so vocabulary stays consistent between school and home.",
        "- Keep the tablet version open during therapy and hand the printed copy to the family.",
      ].join("\n")
    end

    def instant_download_section
      [
        "INSTANT DOWNLOAD",
        "",
        "This is a digital download. No physical item will be shipped, and your files are " \
        "available immediately after purchase.",
        "License: use with your own family, your own students, or your own caseload. Please do " \
        "not resell, redistribute, or share the files outside your household, classroom, or " \
        "practice.",
      ].join("\n")
    end
  end
end
