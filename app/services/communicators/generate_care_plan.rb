# frozen_string_literal: true

module Communicators
  # The communicator care plan — a flowing, multi-page Letter PDF built from
  # settings["care"] and (in the :full variant) the emergency info.
  #
  # Two variants, one class: the documents share everything but a single block,
  # and two classes would fork the care rendering immediately.
  #
  #   :full      "Care & Emergency Plan" — care sections + emergency info
  #   :care_only "Care Plan"             — care sections, no medical data
  #
  # PDF only, no PNG. Every other communicator asset ships both, but a PNG of a
  # three-page document is either one impossibly tall image or a silently
  # cropped first page, and there is nothing that would display it.
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
    LAYOUT_VERSION = 1

    VARIANTS = {
      full: { attachment: :care_emergency_plan_pdf, filename: "care-and-emergency-plan", emergency: true },
      care_only: { attachment: :care_plan_pdf, filename: "care-plan", emergency: false },
    }.freeze

    class UnknownVariant < ArgumentError; end

    def self.call(profile, variant: :full, regenerate: false, locale: I18n.locale, qr_target_url: nil)
      new(profile, variant: variant, locale: locale, qr_target_url: qr_target_url)
        .call(regenerate: regenerate)
    end

    # Whether there is anything worth printing. The endpoint asks BEFORE
    # generating so it can answer 422 — a service that raises can't, and a
    # near-blank document that looks like a finished plan is worse than a
    # refusal.
    def self.printable?(profile, variant: :full)
      document = CarePlanDocument.new(profile)

      config_for(variant)[:emergency] ? document.care? || document.emergency? : document.care?
    end

    def self.config_for(variant)
      VARIANTS.fetch(variant.to_sym) { raise UnknownVariant, "unknown care plan variant" }
    end

    def initialize(profile, variant: :full, locale: I18n.locale, qr_target_url: nil)
      super(profile, qr_target_url: qr_target_url)
      @variant = variant.to_sym
      @config = self.class.config_for(@variant)
      @locale = locale
    end

    attr_reader :variant, :config, :locale

    def call(regenerate: false)
      return profile if !regenerate && attached_and_fresh?(config[:attachment], signature: signature)

      pdf = generate_letter_pdf(rendered_document)

      attach_binary(
        record: profile,
        attachment_name: config[:attachment],
        bytes: pdf,
        filename: "#{config[:filename]}-#{profile.id}.pdf",
        content_type: "application/pdf",
        metadata: { signature: signature },
      )

      profile
    end

    private

    # The variant and locale ride in the signature alongside the layout version.
    # The two variants live in separate attachments so they can't literally
    # collide, but a mistake that crossed them would otherwise serve a care-only
    # download containing medications — cheap insurance for an expensive failure.
    def signature
      asset_signature(
        [
          profile.safety_info_signature,
          "care_plan=#{variant}",
          "locale=#{locale}",
          "v#{LAYOUT_VERSION}",
        ].join("::"),
      )
    end

    def document
      @document ||= CarePlanDocument.new(profile, locale: locale)
    end

    def rendered_document
      I18n.with_locale(locale) do
        ApplicationController.render(
          template: "communicators/assets/care_plan",
          layout: "pdf_care_plan",
          assigns: template_assigns,
        )
      end
    end

    def template_assigns
      {
        title: I18n.t("care.document.title.#{variant}", locale: locale),
        subtitle: I18n.t(
          "care.document.subtitle.#{variant}",
          name: profile.safety_display_name,
          locale: locale,
        ),
        prepared_on: I18n.t(
          "care.document.prepared_on",
          date: I18n.l(Date.current, format: :long, locale: locale),
          locale: locale,
        ),
        display_name: profile.safety_display_name,
        pronouns: (profile.settings || {})["pronouns"].presence,
        # Resolved to a data: URI here, BEFORE the render, so the render itself
        # stays hermetic — the layout's no-network rule holds.
        avatar_data_url: avatar_data_url,
        logo: logo_base64,
        public_url: public_url,
        qr_data_url: qr_data_url_for(public_url),
        emergency: config[:emergency],
        emergency_fields: config[:emergency] ? document.emergency_fields : [],
        emergency_contacts: config[:emergency] ? document.emergency_contacts : [],
        care_sections: document.care_sections,
      }
    end

    def public_url
      effective_qr_url(profile.public_url)
    end

    # The flowing-document counterpart to BaseAssetGenerator#generate_pdf_from_html.
    #
    # That one pins Grover to a fixed pixel page, which is right for a card and
    # wrong for a document — a care plan is however many pages the parent's
    # answers come to, and a fixed height would silently discard the rest.
    # Reaching for the wrong one of these two is the bug this pair exists to
    # make obvious.
    #
    # The margin is NOT decoration. Chrome renders the header and footer in a
    # separate document with none of the page's CSS, and clips them to nothing
    # unless the page reserves margin for them — so `@page { margin: 0 }` (which
    # layouts/pdf_printable.html.erb has) makes the page numbers silently
    # vanish. The empty header_template is equally required: without one Chrome
    # prints its own title-and-date header.
    def generate_letter_pdf(html)
      Grover.new(html, **letter_options).to_pdf
    end

    def letter_options
      Marketing::SheetRendering::LETTER_GROVER_OPTIONS.merge(
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
