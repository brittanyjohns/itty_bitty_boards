# frozen_string_literal: true

# Every word that appears on a marketplace listing slide.
#
# Same reasoning as IncludedItems, which this sits beside: the slides and the
# listing description are read together by one buyer, and duplicating a claim in
# a template is how the two start promising different things. Keeping the
# strings here also means the copy is testable without standing up Grover.
#
# Ported from speakanyway-printables' preview templates
# (src/plugins/aac/templates/previews/about-saw.html and the shared
# branded-frame footer). That repo is authoritative for listings its pipeline
# originates; this is authoritative for listings created from the Rails admin.
# They are allowed to differ — but not by accident.
module Printables
  module SlideCopy
    module_function

    # Bounded on purpose: every one of these sits in a fixed-height band on a
    # 1280px slide. Copy that grows past these lengths doesn't wrap, it
    # overflows into the next element and ships looking broken.
    MAX_BULLET_LENGTH = 72

    def hero_headline(board_count:, topic: nil)
      return "Words for #{topic}" if topic.present?
      return "#{board_count} linked boards — flips like a book" if board_count > 1

      "A printable communication board"
    end

    # The sticker that answers "is this one page or a set?" before a word of
    # copy is read. The headline says the same thing, but a headline is text at
    # ~230px wide in an Etsy search grid, and a number is not.
    #
    # Counts BOARDS, and does not multiply them by the print variants.
    # board_page_count would say "18 PAGES" for a six-board set, which a buyer
    # reads as eighteen distinct pages of vocabulary rather than six pages in
    # three versions. The variants get their own line, spelled out, where they
    # can't be mistaken for content.
    #
    # nil below two boards: "1 LINKED BOARD" undersells a single-page printable
    # and reads as a rendering bug.
    def hero_count_badge(board_count:)
      return nil unless board_count > 1

      {count: board_count.to_s, label: "LINKED\nBOARDS", detail: "COLOUR · LOW-INK · TRIM-READY"}
    end

    # The banner that does the most work in an Etsy grid: it answers "is this a
    # physical thing I have to wait for?" before the buyer opens the listing.
    def instant_download_banner
      "INSTANT DOWNLOAD · READY TO PRINT"
    end

    # "Audio companion", not "voice output": the thing being sold is a printed
    # board, and the phrase has to say that something comes WITH it that speaks.
    # "Voice output" is AAC jargon — an SLP parses it instantly and a parent
    # shopping for their kid does not.
    def audio_companion_badge = "FREE AUDIO COMPANION · EVERY WORD SPEAKS"

    def audio_companion_eyebrow = "Included free"

    def audio_companion_headline = "Scan any page and hear every word out loud"

    def audio_companion_sub = "Works on any phone, tablet or Chromebook. No app, no sign-in."

    # The "on a device" slide. A buyer looking at a printable doesn't know the
    # same board opens on the tablet already on their kitchen table; this is the
    # one slide that shows it rather than saying it.
    # ── The mockup slides ──────────────────────────────────────────────────
    #
    # Four slides share one template and differ only in their copy: two showing
    # the board on a tablet, two showing the printed sheet in a room. Each pair
    # must say a DIFFERENT thing about the same photo — a buyer scrolling past
    # two tablets with one caption between them reads it as the same picture
    # twice, which is exactly the impression the second scene exists to avoid.

    def on_a_device_badge = "THE SAME BOARD · ON ANY TABLET"

    def on_a_device_headline = "Print it, or open it on a screen"

    def on_a_device_bullets
      [
        "Scan the QR and the board opens online",
        "Tap any word and it talks — free",
        "Phone, tablet or Chromebook. No app.",
      ]
    end

    # The second tablet answers the objection the first one creates: "fine, but
    # that's the front page". It is a different room AND a different page.
    def on_a_device_alt_badge = "EVERY PAGE · NOT JUST THE FIRST"

    def on_a_device_alt_headline(board_count:)
      return "Every page opens the same way" if board_count > 1

      "Open it anywhere you already are"
    end

    def on_a_device_alt_bullets(board_count:)
      return [
        "Each page carries its own QR code",
        "Folder tiles open sub-pages, and every one comes back",
        "No sign-in, no app, no dedicated device",
      ] if board_count > 1

      [
        "One code, one tap, the whole board talks",
        "Works on the tablet the family already owns",
        "No sign-in, no app, no dedicated device",
      ]
    end

    # The paper slides are the ones that show the product a buyer actually
    # receives. The first stages it, the second says how long it lasts.
    def on_paper_badge = "PRINT IT TODAY · USE IT TOMORROW"

    def on_paper_headline = "A real board, on real paper"

    def on_paper_bullets
      [
        "Prints on plain Letter paper at home",
        "Full colour, low-ink or trim-ready",
        "The QR on the sheet opens it online, free",
      ]
    end

    def on_paper_alt_badge = "LAMINATE IT · IT LASTS THE YEAR"

    def on_paper_alt_headline(board_count:)
      return "Print the set, ring it, hand it over" if board_count > 1

      "Print it, laminate it, hand it over"
    end

    def on_paper_alt_bullets(board_count:)
      return [
        "Trim-ready pages cut down clean for laminating",
        "Hole-punch and ring the set into a book that flips",
        "Reprint any page, any time — it's yours to keep",
      ] if board_count > 1

      [
        "The trim-ready version cuts down clean for laminating",
        "Survives a school year on a classroom table",
        "Reprint it any time — it's yours to keep",
      ]
    end

    # Small, on every footer strip. A gallery image outlives the listing — it
    # gets pinned, screenshotted and reshared — so it should say where it came
    # from without an Etsy page around it.
    def site_mark = "speakanyway.com"

    def whats_included_title = "What's included"

    # The caption on the low-ink proof card. That slide used to be rendered a
    # second time in full to make this point; one page printed pale beside the
    # colour grid makes it just as well, for one Grover render instead of eight.
    def low_ink_headline = "Also in low-ink — saves your printer"

    # ── The flip-book slides ───────────────────────────────────────────────
    #
    # The claim these three exist to make, and the only one no competing AAC
    # printable can match: the PAGES ARE LINKED. Folder tiles open sub-pages and
    # every sub-page carries a way back, so a printed set navigates the way the
    # app does rather than being a stack of unrelated sheets.
    #
    # Every one of them renders for a single-board printable too. The copy
    # varies; the slide does not disappear. LISTING_IMAGE_ORDER defines what a
    # current gallery is, so a conditional slide would leave small printables
    # permanently stale and permanently re-rendering — see the constant.

    def flip_book_title = "It works like a flip book"

    def flip_book_headline(board_count:)
      return "One page — and the QR turns it into a talking board" unless board_count > 1

      "Folder tiles open a page. Every page has a way back."
    end

    def flip_book_badge = "LINKED PAGES · BACK BUTTONS THAT WORK"

    def flip_book_bullets(board_count:)
      return single_board_flip_book_bullets unless board_count > 1

      [
        "Tap a folder tile, turn to that page",
        "Every page carries a back button home",
        "Bind it once and it navigates like the app",
      ]
    end

    def single_board_flip_book_bullets
      [
        "One sheet, the whole core vocabulary",
        "Scan the QR and the same board talks",
        "Print again any time — it's yours",
      ]
    end

    def assemble_title = "Print it once, use it all year"

    def assemble_headline = "Three minutes from download to a board you can hand over"

    # Four steps, and the third is the one that answers the objection the
    # count sticker creates: "so what do I do with all these sheets?"
    def assemble_steps
      [
        {title: "Print", body: "Plain Letter paper. Colour or low-ink, your call."},
        {title: "Trim", body: "The trim-ready version cuts down clean for laminating."},
        {title: "Hole-punch & ring", body: "Three rings turn the set into a book that flips."},
        {title: "Scan to hear it", body: "Every page's QR opens that page online, free."},
      ]
    end

    def page_index_title(board_count:)
      board_count > 1 ? "Every page in the set" : "What's on this board"
    end

    def page_index_headline(board_count:)
      return "The full vocabulary, on one printable sheet" unless board_count > 1

      "#{board_count} pages, linked — here's every one"
    end

    def about_title = "About SpeakAnyWay"

    def founder_greeting = "Hi, I'm Brittany"

    def founder_paragraphs
      [
        "I'm a mom of two nonspeaking communicators. I built SpeakAnyWay " \
        "because the tools we were handed were expensive, locked to one " \
        "device, and never there when we actually needed them.",
        "Every printable here is one I wanted for my own kids — and every one " \
        "comes with a free audio companion online, so the words are always " \
        "within reach, and always heard.",
      ]
    end

    def why_choose_title = "Why families & teams choose SpeakAnyWay"

    def why_choose_bullets
      [
        "Free audio companion online — no subscription",
        "Works on any device — no app install",
        "Built by a parent who needed it to work",
        "Used by SLPs, teachers, aides and families",
      ]
    end

    # The listing video's frames. Etsy STRIPS a listing video's audio, so every
    # one of these has to be readable rather than narrated — and short, because
    # a page frame is on screen for around a second.
    # "boards", not "pages", and the same word the sticker beside it uses:
    # printing one number as boards in one place and pages in the other is how
    # a buyer starts wondering which of the two they're actually getting.
    def video_intro_headline(board_count:)
      return "Every word. Ready to print." unless board_count > 1

      "#{board_count} linked boards that flip like a book"
    end

    # Sits on each page frame after the first. The claim no other AAC printable
    # on the marketplace makes: the links work on paper.
    def video_back_marker = "◀ back button on every page"

    def video_outro_headline = "Scan any page — every word talks"

    # Two lines, deliberately. As one string the sub wraps wherever the frame
    # runs out of room, which put "in." alone on the last row; the renderer
    # keeps each line unbroken.
    def video_outro_sub_lines = ["Free audio companion.", "No app, no sign-in."]

    def hero_footer_bullets
      [
        "Free audio companion — no app, no subscription",
        "Print at home, use anywhere",
        "Personal & classroom license",
      ]
    end
  end
end
