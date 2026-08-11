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
      return "#{board_count} printable boards in one download" if board_count > 1

      "A printable communication board"
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

    # Small, on every footer strip. A gallery image outlives the listing — it
    # gets pinned, screenshotted and reshared — so it should say where it came
    # from without an Etsy page around it.
    def site_mark = "speakanyway.com"

    def whats_included_title(low_ink: false)
      low_ink ? "Low-ink version included" : "What's included"
    end

    def low_ink_headline = "Every page again in low-ink — saves your printer"

    def how_it_works_title = "How it works"

    def how_it_works_headline = "Every printable comes with a free audio companion"

    # Four steps, not the pipeline's three: "print" and "cut or laminate" are
    # separate jobs for a buyer deciding whether this fits their week, and the
    # laminate step is what makes a board survive a classroom.
    def how_it_works_steps
      [
        {title: "Download", body: "Instant PDF. No waiting, no shipping."},
        {title: "Print", body: "Full colour or low-ink, on plain Letter paper."},
        {title: "Cut & laminate", body: "Optional — laminate to make it last a school year."},
        {title: "Scan to hear it", body: "The QR opens the same board online — tap a word, it talks."},
      ]
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

    def hero_footer_bullets
      [
        "Free audio companion — no app, no subscription",
        "Print at home, use anywhere",
        "Personal & classroom license",
      ]
    end
  end
end
