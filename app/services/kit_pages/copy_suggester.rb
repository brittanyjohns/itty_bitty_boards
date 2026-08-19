module KitPages
  # Writes a whole /kit/:slug landing page from the printable it gives away —
  # eyebrow, title, subhead, the "what's inside" items, and the closing block —
  # in one OpenAI call.
  #
  # The screen it feeds is a lead-magnet form whose only real decision is WHICH
  # printable. Everything else was hand-typed, including a raw JSON blob, so the
  # cost of launching a campaign page was an afternoon of copywriting rather
  # than a dropdown and a button.
  #
  # Two constraints come from outside this class and must not be relaxed here:
  #
  #   * **Never feed it `listing_copy["description"]`.** That is long-form Etsy
  #     marketplace prose — "instant download", "no sign-in required", delivery
  #     mechanics — written for a buyer at a checkout. On a free landing page it
  #     reads as a sales pitch for something already being given away. The
  #     `summary` (capped at 150 chars by Etsy::ListingCopy) is the clean borrow.
  #   * **Every string is rendered as text by the frontend.** KitLandingPage
  #     prints these into headings and paragraphs, so an HTML answer shows up as
  #     literal tags. Markup is stripped here rather than trusted.
  #
  # ONLY EVER POPULATES THE FORM. No writes, no credit charge: admin-owned.
  class CopySuggester
    class GenerationError < StandardError; end

    MAX_EYEBROW_LENGTH = 40
    MAX_TITLE_LENGTH = 80
    MAX_SUBHEAD_LENGTH = 200
    MAX_ITEMS = 6
    MIN_ITEMS = 3
    MAX_ITEM_TITLE_LENGTH = 60
    MAX_ITEM_DESCRIPTION_LENGTH = 140
    MAX_CLOSING_HEADING_LENGTH = 60
    MAX_CLOSING_BODY_LENGTH = 300
    MAX_CTA_LABEL_LENGTH = 24

    # A CTA path is pasted straight into the frontend's router. Anything that
    # isn't a site-relative path — an absolute URL most of all — would send a
    # visitor off the page the campaign paid for.
    CTA_PATH_FORMAT = %r{\A/[a-z0-9\-/]*\z}
    DEFAULT_CTA_PATH = "/sign-up".freeze
    DEFAULT_CTA_LABEL = "Start free".freeze

    # Enough tags to steer the register without pasting the whole listing.
    TAG_SAMPLE_SIZE = 8

    def initialize(slug:, title: nil, printable: nil)
      @slug = slug.to_s.strip
      @title = title.to_s.strip
      @printable = printable
    end

    def call
      if subject.blank?
        raise GenerationError, "pick a printable, or give the page a slug to work from"
      end

      parse_response(generate_via_openai)
    end

    private

    attr_reader :slug, :title, :printable

    # What the page is about, in plain words. The printable's board name is the
    # most specific thing available; the slug is the fallback so the button
    # still works on a page whose download hasn't been chosen yet.
    def subject
      @subject ||= board_name.presence || topic.presence || title.presence || slug.tr("-", " ").strip
    end

    def board_name = printable&.board&.name.to_s.strip

    def topic = printable&.topic.to_s.strip

    def page_count = printable&.page_count.to_i

    def listing_copy = @listing_copy ||= printable ? printable.listing_copy_or_default.to_h : {}

    def summary = listing_copy["summary"].to_s.strip

    def tags
      Array(listing_copy["tags"]).map { |tag| tag.to_s.strip }.reject(&:blank?).first(TAG_SAMPLE_SIZE)
    end

    def generate_via_openai
      client = OpenAiClient.new(
        prompt: subject,
        messages: [{ role: "user", content: build_prompt }],
      )
      client.instance_variable_set(:@model, OpenAiClient::GTP_MODEL)
      result = client.create_chat(true)

      raise GenerationError, "OpenAI returned no content" if result[:content].blank?

      result[:content]
    end

    def build_prompt
      <<~PROMPT
        You are writing a landing page that gives away a free printable AAC
        (Augmentative and Alternative Communication) resource to teachers, therapists
        and parents. A visitor lands here, sees what the printable is, and enters an
        email address to download it.

        The printable is about: #{subject}
        #{topic.present? ? "Its topic: #{topic}" : ""}
        #{page_count.positive? ? "It is #{page_count} pages." : ""}
        #{summary.present? ? "A one-line summary of it: #{summary}" : ""}
        #{tags.any? ? "Keywords: #{tags.join(", ")}" : ""}

        Write the page. Warm, plain, specific. Speak to the adult who will print it,
        never to the child. Say "nonspeaking", never "nonverbal". No exclamation marks,
        no "unlock", no "empower", no marketing throat-clearing. Do not mention Etsy,
        prices, purchases, or instant downloads — this is free.

        Plain text in every field: no HTML, no markdown, no emoji.

        "eyebrow" — a short label for the pill above the headline, at most
        #{MAX_EYEBROW_LENGTH} characters. For example "Free classroom kit".

        "title" — the headline, at most #{MAX_TITLE_LENGTH} characters. Say what the
        thing is, not how great it is.

        "subhead" — one or two sentences under the headline saying who it is for and
        what they can do with it. At most #{MAX_SUBHEAD_LENGTH} characters.

        "items" — between #{MIN_ITEMS} and #{MAX_ITEMS} things that are inside the
        printable. Each has a "title" (at most #{MAX_ITEM_TITLE_LENGTH} characters) and
        a "description" (one concrete sentence, at most
        #{MAX_ITEM_DESCRIPTION_LENGTH} characters). Be concrete about what is on the
        pages rather than restating the benefit.

        "closing" — the block under the list, with "heading" (at most
        #{MAX_CLOSING_HEADING_LENGTH} characters), "body" (one or two sentences, at most
        #{MAX_CLOSING_BODY_LENGTH} characters) inviting them to build their own boards
        in the app, "cta_label" (at most #{MAX_CTA_LABEL_LENGTH} characters) and
        "cta_path" (a site-relative path beginning with "/", normally "#{DEFAULT_CTA_PATH}").

        Respond in JSON format:
        {
          "eyebrow": "Free classroom kit",
          "title": "The at-school communication kit",
          "subhead": "Print it once and put it where the talking happens.",
          "items": [{ "title": "Core word poster", "description": "One page, 36 words, big enough to read across a room." }],
          "closing": { "heading": "Make it yours", "body": "Build the same board in the app and change the words to fit your student.", "cta_label": "#{DEFAULT_CTA_LABEL}", "cta_path": "#{DEFAULT_CTA_PATH}" }
        }

        Return ONLY the JSON, no other text.
      PROMPT
    end

    def parse_response(raw)
      data = JSON.parse(raw)
      raise GenerationError, "AI returned #{data.class.name.downcase}, not an object" unless data.is_a?(Hash)

      copy = {
        eyebrow: clean(data["eyebrow"], MAX_EYEBROW_LENGTH),
        title: clean(data["title"], MAX_TITLE_LENGTH),
        subhead: clean(data["subhead"], MAX_SUBHEAD_LENGTH),
        items: clean_items(data["items"]),
        closing: clean_closing(data["closing"]),
      }

      if copy[:title].blank? && copy[:subhead].blank? && copy[:items].empty?
        raise GenerationError, "AI returned nothing usable"
      end

      copy
    rescue JSON::ParserError => e
      raise GenerationError, "Failed to parse AI response: #{e.message}"
    end

    # Models answer a "short phrase" request with a sentence often enough, and a
    # "plain text" request with markup often enough, to be worth handling rather
    # than trusting.
    def clean(value, limit)
      value.to_s.gsub(/<[^>]*>/, " ").squish.truncate(limit)
    end

    # Order is the model's, so its best material survives the cap. An entry
    # missing both halves is dropped rather than rendered as an empty card.
    def clean_items(raw_items)
      Array(raw_items).filter_map do |item|
        next unless item.is_a?(Hash)

        item_title = clean(item["title"], MAX_ITEM_TITLE_LENGTH)
        description = clean(item["description"], MAX_ITEM_DESCRIPTION_LENGTH)
        next if item_title.blank? && description.blank?

        { "title" => item_title, "description" => description }
      end.first(MAX_ITEMS)
    end

    def clean_closing(raw_closing)
      return {} unless raw_closing.is_a?(Hash)

      closing = {
        "heading" => clean(raw_closing["heading"], MAX_CLOSING_HEADING_LENGTH),
        "body" => clean(raw_closing["body"], MAX_CLOSING_BODY_LENGTH),
        "cta_label" => clean(raw_closing["cta_label"], MAX_CTA_LABEL_LENGTH).presence || DEFAULT_CTA_LABEL,
        "cta_path" => clean_cta_path(raw_closing["cta_path"]),
      }

      closing.values.all?(&:blank?) ? {} : closing
    end

    def clean_cta_path(value)
      path = value.to_s.strip.downcase
      CTA_PATH_FORMAT.match?(path) ? path : DEFAULT_CTA_PATH
    end
  end
end
