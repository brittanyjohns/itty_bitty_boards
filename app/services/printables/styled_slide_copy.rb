# frozen_string_literal: true

# Every word on a STYLED gallery slide (Boards::Printables::RenderStyledSlides).
#
# Same reasoning as SlideCopy: a claim written into a template drifts from the
# listing text it sits beside. Numbers are never written here either — each one
# is read off Printables::GalleryFacts, so "309 words" is only ever said about a
# set that has 309 words.
#
# Bounded on purpose. Every string sits in a fixed box on a 1200x900 canvas;
# copy that outgrows its box overlaps the next one rather than wrapping.
module Printables
  module StyledSlideCopy
    module_function

    TAGLINE = "AAC for a brighter everyday"

    # Past this the name line of the headline wraps to a third line and runs
    # into the feature list, so a long board name falls back to a generic one.
    MAX_HEADLINE_NAME = 22

    # => [kicker, title], drawn as two lines.
    def hero_headline(board_title:, board_count:)
      noun = board_count > 1 ? "Boards" : "Board"
      name = board_title.to_s.sub(/\s*(communication\s+)?boards?\z/i, "").squish
      name = "Communication" if name.blank? || name.length > MAX_HEADLINE_NAME

      ["Printable AAC", "#{name} #{noun}"]
    end

    def hero_features(facts)
      [
        boards_feature(facts, sub: facts.set? ? "Linked pages that open like a book" : "Ready to print and use"),
        words_feature(facts),
        ink_feature(facts),
        { icon: "devices", title: "Print at home or use on any device", sub: "For home, school or on the go" },
        { icon: "sound", title: "Free online version included", sub: "Tap any word and hear it spoken" },
      ].compact
    end

    def hero_badges(facts)
      [facts.letter_size_label, facts.formats_label, "Digital download"]
    end

    # The bottom-centre pill. Only a set has a number worth saying there.
    def hero_set_accent(facts)
      return nil unless facts.set?

      "#{facts.board_count} boards. More possibilities."
    end

    def whats_included_title = "What's included"

    def whats_included_features(facts)
      [
        boards_feature(facts, sub: "Every page in the set", printable: true),
        words_feature(facts),
        ink_feature(facts),
        {
          icon: "file",
          title: facts.pdf_count > 1 ? "#{facts.pdf_count} print-ready PDFs" : "Print-ready PDF",
          sub: "High-quality files, ready to print",
        },
        { icon: "home", title: "Personal + classroom use", sub: "At home, at school or on the go" },
      ].compact
    end

    def whats_included_badges(facts)
      [facts.letter_size_label, "Print at home or use on any device", "Instant download"]
    end

    def whats_included_corner_accent(facts)
      facts.set? ? "#{facts.board_count} boards. So many possibilities!" : "Everything you need to start"
    end

    # The root's own name when it fits, because "start on Core 60" is advice a
    # buyer can follow and "start on the main board" is filler.
    def whats_included_footer_accent(facts, root_title:)
      return "Print it, laminate it, use it every day." unless facts.set?
      return "Start on the main board, then open the linked pages." if root_title.blank? || root_title.length > 18

      "Start on #{root_title}, then open the linked pages."
    end

    # ── Color + low-ink ─────────────────────────────────────────────────────
    #
    # With no low-ink file there is no "options" to speak of, and the slide
    # shows the colour page alone; nothing on it may mention low ink.

    def color_low_ink_headline(facts) = facts.low_ink? ? "Color + low-ink options" : "Bright full-color pages"

    def color_low_ink_subline = "Print at home or at school"

    def color_version_label = "Full Color Version"

    def low_ink_version_label = "Low-Ink Version"

    # Short pills, one line each. No "no bleed, no trimming": the printed page
    # runs to within 3mm of the sheet edge (layouts/pdf: @page margin 0, .page
    # padding 3mm) and a trim-ready PDF exists, so neither half is a claim the
    # files back.
    def color_low_ink_features(facts)
      [
        { icon: "file", title: "US Letter #{facts.letter_size_label}" },
        { icon: "printer", title: "Great for home printers" },
        if facts.low_ink?
          { icon: "drop", title: "Printer-friendly low-ink version" }
        else
          { icon: "palette", title: "Bright, full-color pages" }
        end,
        { icon: "shield", title: "Laminate for extra durability" },
      ]
    end

    # ── Online version ──────────────────────────────────────────────────────
    #
    # "Free" and "No sign-in required" are claims about a buyer with no
    # account, so they need every board published (GalleryFacts#online_public?).
    # Without it the slide still shows the tablet and the steps, and says only
    # what holds for anyone: it is a web page, so there is no app to install.

    def online_headline(facts) = facts.online_public? ? "Free online version included" : "Print it or open it online"

    def online_subline(facts)
      facts.set? ? "Every page's QR code opens that page" : "The QR code on the page opens the board"
    end

    def online_steps
      [
        { icon: "download", title: "Download" },
        { icon: "devices", title: "Print or open on any device" },
        { icon: "qr", title: "Scan the QR code" },
        { icon: "sound", title: "Tap a word and it speaks" },
      ]
    end

    def online_checks(facts)
      if facts.online_public?
        ["Free online version included", "No app install", "No sign-in required", "Use in your browser anytime"]
      else
        ["No app install", "Works in a web browser"]
      end
    end

    def online_paper_accent = "Scan me!"

    def accents
      {
        top_right: "Words within reach",
        bottom_left: "Support communication every day",
        bottom_right: %w[Speak Connect Belong],
      }
    end

    def boards_feature(facts, sub:, printable: false)
      noun = facts.board_count == 1 ? "board" : "boards"
      adjective = printable ? "printable communication" : "communication"
      { icon: "boards", title: "#{facts.board_count} #{adjective} #{noun}", sub: sub }
    end

    # Dropped rather than printed as "0 symbol-supported words".
    def words_feature(facts)
      count = facts.word_count
      return nil unless count.positive?

      noun = count == 1 ? "word" : "words"
      { icon: "words", title: "#{count} symbol-supported #{noun}", sub: "Build language and independence" }
    end

    def ink_feature(facts)
      if facts.low_ink?
        { icon: "printer", title: "Color + low-ink versions", sub: "Bright or printer-friendly" }
      else
        { icon: "printer", title: "Full-color pages", sub: "Bright and ready to print" }
      end
    end
  end
end
