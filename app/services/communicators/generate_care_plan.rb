# frozen_string_literal: true

module Communicators
  # The communicator care plan — built from settings["care"] and (in the
  # :full variant) the emergency info, at one of three physical sizes.
  #
  # Two variants, one class: the documents share everything but a single block,
  # and two classes would fork the care rendering immediately.
  #
  #   :full      "Care & Emergency Plan" — care sections + emergency info
  #   :care_only "Care Plan"             — care sections, no medical data
  #
  # Three sizes, same class again — they share every derived string
  # (CarePlanDocument#glance_how_i_talk, #allergies, ...) and the whole design
  # system (layouts/pdf_care_plan.html.erb); only the template and the Grover
  # page options change.
  #
  #   :sheet  (default) a flowing, multi-page Letter document — fridge, binder
  #   :half   one Letter page, folded once — substitute teacher, sitter
  #   :wallet one Letter page, 4-up strips, cut and folded — lanyard, bus driver
  #
  # `:care_only` + `:wallet` is not offered: strip the emergency block out of a
  # wallet card and what's left is a name, a photo, and a few care lines, which
  # isn't worth the paper. See .supported?.
  #
  # Each document ships a PDF and a PNG thumbnail, rendered from the SAME HTML
  # string in one call so the ERB is evaluated once and the two can never
  # disagree. The PNG is a preview, not a second deliverable: it is what the
  # Print & share tab shows, and it captures the viewport rather than the whole
  # page, so on the flowing :sheet size it is page one. That is the honest
  # thing to show for a document whose length depends on how much the parent
  # filled in — the earlier objection to a PNG here was that a multi-page
  # document rasterizes to either an impossibly tall image or a silently
  # cropped first page, which is true only while nothing tells the reader which
  # one they are looking at. A thumbnail beside a Download button does.
  #
  # NOT generated from Profile#generate_attachments!. That runs synchronously on
  # every safety-profile save — an avatar upload, a theme tweak — and is already
  # four headless-Chrome renders. These are generated on demand, from the
  # endpoint, and the freshness signature makes a repeat download free.
  class GenerateCarePlan < BaseAssetGenerator
    # Bump when the TEMPLATE or LAYOUT changes in a way that should reach
    # documents already generated. safety_info_signature only moves when the
    # PROFILE changes, so without this a redesign leaves every cached PDF stale
    # forever — a gap the existing card generators still have.
    # 2: condensed layout — merged header band, two-column emergency grid,
    #    omitted blank emergency fields, two-column care sections.
    # 3: the band's "SpeakAnyWay" eyebrow is gone — the communicator's name is
    #    the first thing read on a sheet that exists to introduce them, and the
    #    mark still signs the footnote on every page.
    # 4: visual redesign (identity card, per-section colour + icons, chips,
    #    "At a glance" strip, red-rail emergency block) plus the half and
    #    wallet sizes.
    # 5: fold-size rebalance — the glance strip's duplicate "Call first" cell
    #    is gone, the wallet's contacts moved to its front face, and neither
    #    fold size shrinks-and-clips a face any more.
    # 6: the line under the name is the caller's `subheader`, not a sentence
    #    derived from the communication section.
    LAYOUT_VERSION = 6

    SIZES = %w[sheet half wallet].freeze

    # `preview` sits beside `attachment` rather than in a parallel table, so the
    # [variant, size] lookup stays the one place a pair resolves. A size added
    # here without a preview would attach nothing and show a placeholder
    # forever, which is why they travel together.
    VARIANTS = {
      full: {
        emergency: true,
        sizes: {
          sheet: {
            attachment: :care_emergency_plan_pdf,
            preview: :care_emergency_plan_preview_png,
            filename: "care-and-emergency-plan",
          },
          half: {
            attachment: :care_emergency_plan_half_pdf,
            preview: :care_emergency_plan_half_preview_png,
            filename: "care-and-emergency-plan-half",
          },
          wallet: {
            attachment: :care_emergency_plan_wallet_pdf,
            preview: :care_emergency_plan_wallet_preview_png,
            filename: "care-and-emergency-plan-wallet",
          },
        },
      },
      care_only: {
        emergency: false,
        sizes: {
          sheet: {
            attachment: :care_plan_pdf,
            preview: :care_plan_preview_png,
            filename: "care-plan",
          },
          half: {
            attachment: :care_plan_half_pdf,
            preview: :care_plan_half_preview_png,
            filename: "care-plan-half",
          },
          # No :wallet here, deliberately — see the class comment.
        },
      },
    }.freeze

    # The preview's pixel size: US Letter at 96dpi, the ratio every one of these
    # documents prints at. Rendered at 2x for a crisp thumbnail on a retina
    # screen, matching the device tag's scale.
    PREVIEW_WIDTH = 816
    PREVIEW_HEIGHT = 1056

    # How many values the half page's middle overflow tier shows per
    # multi_select field before falling back to comma-joined text (see
    # CarePlanDocument#half_condensed?) — chosen so a maxed field
    # (Profile::MAX_CARE_MULTI_SELECT values) still fits a wrapped line.
    HALF_CONDENSED_MAX_VALUES = 6
    # The wallet card's hard caps. The back face is day-to-day lines and
    # nothing else now that the contacts print on the front, which bought
    # roughly two more lines of room — so the limit went up, not down.
    #
    # Each line is ALSO capped in length, and that cap is the load-bearing
    # half: a maxed-out section's joined values run to hundreds of characters
    # on their own, and a line that wraps costs the same room as two. The two
    # numbers are one budget — 62 characters is at most two visual lines in
    # the value column, and six of those fill the face.
    WALLET_LINE_LIMIT = 6
    WALLET_LINE_MAX_CHARS = 62
    # The line under the communicator's name, on the sheet and half sizes.
    #
    # It is a per-download CHOICE, not stored data: `subheader` supplies the
    # words and `include_subheader: false` drops the line entirely. Blank or
    # absent means the default copy, which lives in the locale files and is
    # resolved at RENDER time — never written anywhere. That is the same rule
    # `profiles.bio` / `profiles.intro` are under: this line prints in the
    # communicator's own first-person voice, so seeding it would publish words
    # nobody wrote and make "is there a subheader" stop meaning "did someone
    # write one".
    #
    # It used to be derived from the communication section
    # ("I communicate using AAC device and gestures. Keep my device close."),
    # which repeated the "How I talk" cell in the glance strip a centimetre
    # below it. The glance strip still carries that fact; this line is now
    # what the person handing the card over wants a stranger to read first.
    #
    # The cap exists because the text rides the freshness signature, same
    # reason `sections` is capped in the controller — and because two printed
    # lines under the name is the most the identity block can hold before it
    # starts competing with the name again.
    SUBHEADER_MAX_CHARS = 160

    # The half page's own last-resort tier: more generous than the wallet's,
    # since a 4.5in back panel has room for it. It needs the per-line cap for
    # the same reason the wallet does, though — the line COUNT alone bounds
    # nothing when one maxed-out section joins to 400-plus characters and wraps
    # to four visual lines on its own. Eight lines at two wrapped lines each is
    # what the panel holds under the footnote.
    HALF_TRUNCATED_LINE_LIMIT = 8
    HALF_TRUNCATED_LINE_MAX_CHARS = 240

    class UnknownVariant < ArgumentError; end
    class UnsupportedSize < ArgumentError; end

    def self.call(profile, variant: :full, size: :sheet, regenerate: false, locale: I18n.locale,
                  qr_target_url: nil, sections: nil, subheader: nil, include_subheader: true)
      new(profile, variant: variant, size: size, locale: locale, qr_target_url: qr_target_url,
        sections: sections, subheader: subheader, include_subheader: include_subheader)
        .call(regenerate: regenerate)
    end

    # Whether there is anything worth printing. The endpoint asks BEFORE
    # generating so it can answer 422 — a service that raises can't, and a
    # near-blank document that looks like a finished plan is worse than a
    # refusal.
    #
    # The section selection has to reach this check too, or a :care_only request
    # narrowed down to nothing prints the sheet of empty headings the 422 exists
    # to refuse. Printability is about CONTENT, not paper size, so `size` rides
    # along for interface symmetry with .call but doesn't change the answer.
    def self.printable?(profile, variant: :full, size: :sheet, sections: nil)
      document = CarePlanDocument.new(profile, only_sections: sections)

      variant_config(variant)[:emergency] ? document.care? || document.emergency? : document.care?
    end

    def self.variant_config(variant)
      VARIANTS.fetch(variant.to_sym) { raise UnknownVariant, "unknown care plan variant" }
    end

    # Whether this [variant, size] pair is offered at all — the one gap is
    # :care_only + :wallet. Never raises: the endpoint uses this to answer 422
    # unsupported_size rather than emitting a card not worth the paper.
    def self.supported?(variant, size)
      variant_config(variant)[:sizes].key?(size.to_sym)
    rescue UnknownVariant
      false
    end

    def self.config_for(variant, size)
      variant_config(variant)[:sizes].fetch(size.to_sym) { raise UnsupportedSize, "unsupported size for this variant" }
    end

    def initialize(profile, variant: :full, size: :sheet, locale: I18n.locale, qr_target_url: nil,
                   sections: nil, subheader: nil, include_subheader: true)
      super(profile, qr_target_url: qr_target_url)
      @variant = variant.to_sym
      @size = size.to_sym
      @config = self.class.config_for(@variant, @size)
      @emergency = self.class.variant_config(@variant)[:emergency]
      @locale = locale
      # nil means every section — see the note on CarePlanDocument#initialize.
      @sections = sections.nil? ? nil : Array(sections).map { |key| key.to_s.strip }.reject(&:empty?)
      # Blank and absent are the same answer here — both mean "the default
      # copy" — unlike `sections`, where [] is a real request for none.
      @subheader = subheader.to_s.strip.presence&.slice(0, SUBHEADER_MAX_CHARS)
      @include_subheader = include_subheader != false
    end

    attr_reader :variant, :size, :config, :emergency, :locale, :sections, :subheader, :include_subheader

    # There is one attachment per [variant, size], not per selection, so a
    # narrowed download replaces the stored document and the URL on
    # Profile#api_view points at the narrowed sheet until the next download.
    # That is deliberate — the screen regenerates on every click, so it
    # self-corrects — and an attachment per selection would be unbounded.
    def call(regenerate: false)
      return profile if !regenerate && up_to_date?

      # Rendered ONCE and handed to Grover twice. The ERB is the expensive,
      # side-effect-carrying half (it resolves the avatar to a data: URI and
      # walks the whole care blob); rendering it per output would double that
      # work and let the PDF and its own thumbnail drift apart.
      html = rendered_document

      attach_binary(
        record: profile,
        attachment_name: config[:attachment],
        bytes: generate_pdf(html),
        filename: "#{config[:filename]}-#{profile.id}.pdf",
        content_type: "application/pdf",
        metadata: { signature: signature },
      )

      attach_binary(
        record: profile,
        attachment_name: config[:preview],
        bytes: generate_preview(html),
        filename: "#{config[:filename]}-#{profile.id}-preview.png",
        content_type: "image/png",
        metadata: { signature: signature },
      )

      profile
    end

    private

    # The variant, size, and locale ride in the signature alongside the layout
    # version. The variants (and now sizes) live in separate attachments so
    # they can't literally collide, but a mistake that crossed them would
    # otherwise serve a care-only download containing medications, or a wallet
    # card to someone who asked for a sheet — cheap insurance for an expensive
    # failure. `size` is unconditional, unlike `sections` below: every existing
    # signature predates the size param, but this ships alongside the
    # LAYOUT_VERSION bump that already invalidates them, so there is no
    # untouched history to preserve.
    #
    # The section selection rides along too, and it MUST: the two variants share
    # one attachment each, so without it a narrowed download is answered by the
    # cached full document and the picker silently does nothing. Omitted
    # entirely when nothing was selected away, so an unfiltered download keeps
    # the signature it has always had.
    def signature
      asset_signature(
        [
          profile.safety_info_signature,
          "care_plan=#{variant}",
          "size=#{size}",
          "locale=#{locale}",
          ("sections=#{sections.sort.join(",")}" if sections),
          subheader_signature,
          "v#{LAYOUT_VERSION}",
        ].compact.join("::"),
      )
    end

    # Omitted entirely when the caller took the default, so an ordinary
    # download keeps the signature it has always had — the same rule
    # `sections` follows. It has to be here at all for the same reason
    # `sections` does: there is one attachment per [variant, size], so without
    # it a custom or hidden subheader is answered by the cached document and
    # the control silently does nothing.
    def subheader_signature
      return "subheader=off" unless include_subheader
      return if subheader.nil?

      "subheader=#{subheader}"
    end

    # The words that print under the name, or nil for no line at all. The
    # default is resolved HERE, at render time, and never stored — see the
    # note on SUBHEADER_MAX_CHARS.
    def resolved_subheader
      return nil unless include_subheader

      subheader || I18n.t("care.document.subheader.default", locale: locale)
    end

    def document
      @document ||= CarePlanDocument.new(profile, locale: locale, only_sections: sections)
    end

    def rendered_document
      I18n.with_locale(locale) do
        ApplicationController.render(
          template: template_name,
          layout: "pdf_care_plan",
          assigns: template_assigns,
        )
      end
    end

    def template_name
      case size
      when :half then "communicators/assets/care_plan_half"
      when :wallet then "communicators/assets/care_plan_wallet"
      else "communicators/assets/care_plan"
      end
    end

    def template_assigns
      {
        # No subtitle: the identity card carries the doctype line and the
        # subheader, and "How to support Rosa day to day" is the one line on
        # the old sheet a reader already knows. care.document.subtitle is left
        # in the locale files for whoever brings it back.
        #
        # No prepared-on date either: the sheet lives in a backpack or a school
        # folder for a whole year, and a printed date only makes a still-current
        # plan look stale. care.document.prepared_on stays in the locale files.
        title: I18n.t("care.document.title.#{variant}", locale: locale),
        display_name: profile.safety_display_name,
        pronouns: (profile.settings || {})["pronouns"].presence,
        # Resolved to a data: URI here, BEFORE the render, so the render itself
        # stays hermetic — the layout's no-network rule holds.
        avatar_data_url: avatar_data_url,
        logo: logo_base64,
        public_url: public_url,
        qr_data_url: qr_data_url_for(public_url),
        emergency: emergency,
        emergency_fields: emergency ? document.emergency_fields : [],
        blank_emergency_field_names: emergency ? document.blank_emergency_field_names : [],
        emergency_contacts: emergency ? document.emergency_contacts : [],
        care_sections: document.care_sections,
        # The line under the name. Shown on both variants — it is not emergency
        # data, it is the introduction the identity block exists to make.
        # Rendered by the sheet and half sizes; the wallet's 2in front face has
        # no room for it and doesn't ask for it.
        subheader: resolved_subheader,
        # The "At a glance" strip only ever renders on the :full variant (see
        # the templates): allergies IS emergency data, so it's computed only
        # when this document carries emergency info at all, mirroring the
        # pattern above rather than trusting the template's `if @emergency`
        # guard alone.
        glance_how_i_talk: document.glance_how_i_talk,
        allergies: emergency ? document.allergies : nil,
        # Only the half and wallet templates use these; harmless to compute
        # for :sheet too since both are cheap (no rendering happens here).
        half_condensed: document.half_condensed?,
        half_truncated: document.half_truncated?,
        care_sections_condensed: document.care_sections(max_values: HALF_CONDENSED_MAX_VALUES),
        half_condensed_lines: document.condensed_care_lines(
          limit: HALF_TRUNCATED_LINE_LIMIT, truncate_at: HALF_TRUNCATED_LINE_MAX_CHARS,
        ),
        wallet_lines: document.condensed_care_lines(limit: WALLET_LINE_LIMIT, truncate_at: WALLET_LINE_MAX_CHARS),
      }
    end

    # `permanent_url` — a care plan is printed and handed to a school, so its
    # QR (and the URL printed beside it) must outlive the owner changing or
    # revoking their public link. Same rule as the device tag.
    def public_url
      effective_qr_url(profile.permanent_url)
    end

    # The counterpart to BaseAssetGenerator#generate_pdf_from_html, for a page
    # sized by CSS rather than by fixed pixels.
    #
    # :sheet flows to however many pages the parent's answers come to — a fixed
    # height would silently discard the rest. :half and :wallet are fixed
    # single pages, but still CSS-sized (`@page { size: letter }` in the
    # layout) rather than pinned to a pixel viewport, because their content is
    # laid out in physical units (in, pt) that only make sense against a real
    # page size.
    def generate_pdf(html)
      Grover.new(html, **letter_options).to_pdf
    end

    # Both artifacts, or neither. Checking only the PDF would mean a document
    # generated before previews existed is "fresh" forever and never grows one
    # — the download would keep working and the thumbnail beside it would stay
    # a placeholder, with no way for the owner to force it but a section change.
    # This is what backfills previews onto already-cached documents, which is
    # why no LAYOUT_VERSION bump ships with them: the PDF bytes are unchanged,
    # and a bump would rebuild every cached document to no purpose.
    def up_to_date?
      attached_and_fresh?(config[:attachment], signature: signature) &&
        attached_and_fresh?(config[:preview], signature: signature)
    end

    # A screenshot, not a print — see the @media screen block in
    # layouts/pdf_care_plan.html.erb, which is what gives the `sheet` size the
    # page margins Grover's PDF options supply on paper.
    #
    # HtmlToPng captures the VIEWPORT rather than the full page, which is the
    # useful behaviour here: `sheet` flows to however many pages the parent's
    # answers come to, and one Letter-shaped viewport of it is page one.
    # `half` and `wallet` are single Letter pages already, so the same viewport
    # captures them whole.
    def generate_preview(html)
      HtmlToPng.call(html: html, width: PREVIEW_WIDTH, height: PREVIEW_HEIGHT)
    end

    # :sheet keeps the header/footer Chrome renders in a separate document —
    # see the note on #footer_template. :half and :wallet get neither: a folded
    # card or a cut-and-folded wallet strip does not get page numbers, and
    # `margin: 0` is what lets their CSS lay out content against the FULL,
    # untrimmed page (the fold/cut lines are measured from the physical edge).
    #
    # The margin is NOT decoration on either branch. For :sheet, Chrome renders
    # the header and footer in a separate document with none of the page's CSS
    # and clips them to nothing unless the page reserves margin for them — so
    # `@page { margin: 0 }` (which layouts/pdf_printable.html.erb has) makes the
    # page numbers silently vanish. The empty header_template is equally
    # required: without one Chrome prints its own title-and-date header.
    def letter_options
      base = Marketing::SheetRendering::LETTER_GROVER_OPTIONS
      return base.merge(display_header_footer: false, margin: 0) unless size == :sheet

      base.merge(
        display_header_footer: true,
        header_template: "<span></span>",
        footer_template: footer_template,
        margin: { top: "0.5in", bottom: "0.55in", left: "0.5in", right: "0.5in" },
      )
    end

    # Self-contained by necessity — the footer document inherits no CSS from the
    # page and cannot load the inlined font, so the size and stack are declared
    # inline and the stack is a system one.
    def footer_template
      name = ERB::Util.html_escape(profile.safety_display_name)
      page_word = ERB::Util.html_escape(I18n.t("care.document.page_of", locale: locale))

      <<~HTML
        <div style="width:100%;font-size:7pt;color:#5A5A5A;
                    font-family:Helvetica,Arial,sans-serif;
                    padding:0 0.5in;display:flex;justify-content:space-between;">
          <span>#{name}</span>
          <span>#{page_word} <span class="pageNumber"></span> / <span class="totalPages"></span></span>
        </div>
      HTML
    end
  end
end
