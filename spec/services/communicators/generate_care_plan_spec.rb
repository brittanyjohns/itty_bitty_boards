# frozen_string_literal: true

require "rails_helper"

# There is no Chrome in CI, so Grover is stubbed and these assert against the
# RENDERED HTML and the resolved Grover options. That is the better test anyway:
# the load-bearing claim — that the care-only document leaks no emergency value
# — is a substring check, and it would be unreadable against PDF bytes.
#
# ApplicationController.render is deliberately NOT stubbed, so an ERB or layout
# typo fails here rather than in production.
RSpec.describe Communicators::GenerateCarePlan do
  let(:user) { create(:user) }
  let(:account) { create(:child_account, user: user, owner: user, name: "Rosa") }
  # Profile#name reads through to profileable.name — it is not a column.
  let(:profile) do
    Profile.create!(profileable: account,
                    username: "plan-#{SecureRandom.hex(2)}",
                    slug: "plan-#{SecureRandom.hex(2)}")
  end

  let(:care) do
    {
      "order" => %w[communication meals],
      "sections" => {
        "communication" => {
          "enabled" => true,
          "values" => { "methods" => %w[aac_device eye_gaze], "what_helps" => ["wait_and_pause"] },
        },
        "meals" => {
          "values" => { "textures" => ["thickened_liquids"], "preferences" => "hates cold food" },
          "items" => [{ "label" => "Drinks", "value" => "watered-down apple juice" }],
        },
        "c_7f3a91" => {
          "custom" => true,
          "title" => "Bedtime",
          "items" => [{ "label" => "Lights", "value" => "off by seven" }],
        },
      },
    }
  end

  # Distinctive strings so a leak check can't accidentally pass on a substring
  # that appears in the layout.
  let(:emergency) do
    {
      "allergies" => "zzpeanutszz",
      "medical_conditions" => "zzasthmazz",
      "medications" => "zzmelatoninzz",
      "emergency_notes" => "zznotesszz",
      "ice_contact_1" => { "name" => "zzSamzz", "phone" => "555-0100", "relationship" => "Dad" },
    }
  end

  # A generate makes TWO Grover calls off ONE render — the PDF, and the PNG
  # thumbnail rasterized from the same HTML string — so every stub here has to
  # answer both messages, and "it re-rendered" is two calls rather than one.
  def grover_double
    instance_double(Grover, to_pdf: "%PDF-stub", to_png: "\x89PNG-stub")
  end

  # Captures the HTML handed to Grover instead of rendering anything. Both
  # calls are handed the identical string — that is the point of rendering the
  # ERB once — so the first one is the document.
  def render_html(variant: :full, **kwargs)
    captured = nil
    allow(Grover).to receive(:new) do |html, **_opts|
      captured ||= html
      grover_double
    end

    described_class.call(profile.reload, variant: variant, **kwargs)
    captured
  end

  # The rendered document minus the layout's <style> block — the CSS carries
  # explanatory comments naming the very strings some of these assertions
  # check the absence of.
  def document_body(html)
    html.split("</style>").last
  end

  # Each wallet strip as a [back_face, front_face] pair. The strip's markup is
  # back, fold rule, front — see _care_plan_wallet_strip.html.erb.
  def wallet_strips(html)
    document_body(html).split(%(<div class="wstrip">)).drop(1).map do |strip|
      back, front = strip.split(%(<div class="foldrule"))
      [back, front]
    end
  end

  # The PDF call's options specifically. The thumbnail's call carries
  # `format: "png"` and a pixel viewport instead of page options, so capturing
  # the LAST call would quietly assert against the preview rather than the
  # document — and every page-option expectation below would go green while
  # testing nothing.
  def grover_options(variant: :full, size: :sheet)
    captured = nil
    allow(Grover).to receive(:new) do |_html, **opts|
      captured ||= opts unless opts[:format].to_s == "png"
      grover_double
    end

    described_class.call(profile.reload, variant: variant, size: size)
    captured
  end

  # The thumbnail's own Grover options, for the preview expectations.
  def preview_grover_options(variant: :full, size: :sheet)
    captured = nil
    allow(Grover).to receive(:new) do |_html, **opts|
      captured ||= opts if opts[:format].to_s == "png"
      grover_double
    end

    described_class.call(profile.reload, variant: variant, size: size)
    captured
  end

  # A re-render is the PDF call plus the thumbnail's.
  def expect_rerender
    expect(Grover).to receive(:new).twice.and_return(grover_double)
  end

  # The visible text of the identity block, in order — everything from the
  # identity header to whatever section follows it, tags stripped. Asserting on
  # the ORDER matters: "no SpeakAnyWay brand text here" is the claim, and a
  # check for the absence of one particular string would pass again the moment
  # someone put different brand copy back.
  def identity_text(html)
    identity = html[/<header class="identity">.*?(?=<section|<div class="care-heading"|<div class="footnote")/m]
    raise "no identity block in the rendered document" unless identity

    identity.gsub(/<[^>]+>/, "\n").split("\n").map { |line| CGI.unescapeHTML(line.strip) }.reject(&:empty?)
  end

  # A profile with every documented care limit maxed out: all six built-in
  # sections at Profile::MAX_CARE_MULTI_SELECT values per multi_select field
  # and Profile::CARE_SHORT_TEXT_MAX characters per short_text field, plus
  # Profile::MAX_CUSTOM_CARE_SECTIONS custom sections of
  # Profile::MAX_CARE_CUSTOM_ITEMS items each. Written via update_columns to
  # bypass Profile#sanitize_care_settings, which would otherwise strip
  # synthetic option keys that aren't in CareLabels/accepted_care_options —
  # the resolver only needs a key it can label (falling back to humanize), not
  # a "real" one.
  def maxed_out_care_settings
    built_in = Profile::CARE_SECTIONS.each_with_object({}) do |(key, spec), acc|
      values = spec[:fields].each_with_object({}) do |field, values_acc|
        values_acc[field[:key]] =
          if field[:type] == :multi_select
            Array.new(Profile::MAX_CARE_MULTI_SELECT) { |i| "opt_#{i}" }
          else
            "x" * Profile::CARE_SHORT_TEXT_MAX
          end
      end
      acc[key] = { "enabled" => true, "values" => values }
    end

    custom = (0...Profile::MAX_CUSTOM_CARE_SECTIONS).each_with_object({}) do |i, acc|
      acc[format("c_%06x", i)] = {
        "custom" => true,
        "title" => "Custom section #{i}",
        "items" => Array.new(Profile::MAX_CARE_CUSTOM_ITEMS) { |j| { "label" => "Item #{j}", "value" => "v" * 60 } },
      }
    end

    sections = built_in.merge(custom)

    {
      "care" => { "order" => sections.keys, "sections" => sections },
      "allergies" => "peanuts, shellfish, tree nuts, latex",
      "medical_conditions" => "x" * Profile::CARE_SHORT_TEXT_MAX,
      "medications" => "x" * Profile::CARE_SHORT_TEXT_MAX,
      "emergency_notes" => "x" * Profile::CARE_SHORT_TEXT_MAX,
      "ice_contact_1" => { "name" => "Parent One", "phone" => "555-0000", "relationship" => "Mom" },
      "ice_contact_2" => { "name" => "Parent Two", "phone" => "555-0001", "relationship" => "Dad" },
    }
  end

  # settings holds care under "care", plus the emergency keys at the top level.
  before do
    profile.update!(settings: { "care" => care }.merge(emergency))
  end

  describe "the care-only variant" do
    # THE assertion this whole feature turns on. A document a parent hands to a
    # bus driver must not carry medications.
    it "contains no emergency value anywhere" do
      html = render_html(variant: :care_only)

      %w[zzpeanutszz zzasthmazz zzmelatoninzz zznotesszz zzSamzz 555-0100].each do |secret|
        expect(html).not_to include(secret), "care-only plan leaked #{secret}"
      end
    end

    it "does not print the emergency heading" do
      expect(render_html(variant: :care_only)).not_to include("Emergency information")
    end

    it "still contains the care content" do
      html = render_html(variant: :care_only)

      expect(html).to include("Care Plan")
      expect(html).to include("AAC device")
      expect(html).to include("watered-down apple juice")
    end

    it "attaches to care_plan_pdf, and leaves the combined attachment alone" do
      render_html(variant: :care_only)

      expect(profile.reload.care_plan_pdf).to be_attached
      expect(profile.care_emergency_plan_pdf).not_to be_attached
    end

    it "is not offered at the wallet size" do
      expect(described_class.supported?("care_only", "wallet")).to be(false)
      expect(described_class.supported?("care_only", "sheet")).to be(true)
      expect(described_class.supported?("care_only", "half")).to be(true)
    end
  end

  describe "the full variant" do
    it "carries both the emergency block and the care sections" do
      html = render_html(variant: :full)

      expect(html).to include("Care &amp; Emergency Plan").or include("Care & Emergency Plan")
      expect(html).to include("zzpeanutszz")
      expect(html).to include("zzSamzz")
      expect(html).to include("AAC device")
    end

    # Under OMIT_BLANK_EMERGENCY_FIELDS a blank field costs no row. The honest
    # signal — nobody answered — survives as one muted line naming them, which
    # is the whole reason that line exists.
    it "omits an empty emergency field and names it in the not-provided line" do
      profile.update!(settings: { "care" => care }.merge(emergency.except("medications")))

      html = render_html(variant: :full)

      # The rendered cell, not the bare word — "Medications" also appears in a
      # layout comment, and the label is what costs a row. Allergies is no
      # longer in this grid at all — see the "at a glance" describe below.
      expect(html).to include(%(<span class="k">Medical conditions</span>))
      expect(html).not_to include(%(<span class="k">Medications</span>))
      expect(html).to include("No medications or other conditions were provided.")
    end

    it "drops the not-provided line entirely when every field is answered" do
      profile.update!(settings: { "care" => care }.merge(
        emergency.merge("other_conditions" => "zzglasseszz"),
      ))

      html = render_html(variant: :full)

      expect(html).to include("zzglasseszz")
      expect(html).not_to include("were provided")
    end

    it "attaches to care_emergency_plan_pdf" do
      render_html(variant: :full)

      expect(profile.reload.care_emergency_plan_pdf).to be_attached
      expect(profile.care_plan_pdf).not_to be_attached
    end

    it "attaches a PDF and no PNG — a multi-page document has no image form" do
      render_html(variant: :full)

      expect(profile.reload.care_emergency_plan_pdf.content_type).to eq("application/pdf")
      expect(profile).not_to respond_to(:care_plan_png)
    end
  end

  # The "At a glance" strip: allergies and how the communicator talks — only on
  # the :full variant, and allergies renders here and ONLY here.
  describe "the at-a-glance strip" do
    it "prints allergies exactly once, in the glance strip, never in the emergency grid" do
      html = render_html(variant: :full)

      expect(html.scan("zzpeanutszz").length).to eq(1)
      expect(html).not_to include(%(<span class="k">Allergies</span>))
      expect(html).to include(%(<div class="k">Allergies</div>))
    end

    # The strip used to carry a third "Call first" cell repeating the top
    # contact's phone number a few millimetres above the contact cards in the
    # emergency block directly below it, on both sizes that render the strip.
    it "does not repeat a contact's number above the emergency block" do
      %i[sheet half].each do |size|
        body = document_body(render_html(variant: :full, size: size))

        expect(body.scan("555-0100").length).to eq(1)
        expect(body).not_to include("Call first")
        expect(body.scan(%(class="cell)).length).to eq(2)
      end
    end

    it "falls back to a neutral cell when a value is unanswered" do
      profile.update!(settings: { "care" => {} }.merge(emergency.except("allergies")))

      html = render_html(variant: :full)

      expect(html).to include("None listed")
    end

    it "does not render at all for the care-only variant" do
      html = render_html(variant: :care_only)

      expect(html).not_to include(%(class="glance"))
    end
  end

  describe "rendering" do
    it "labels every option rather than printing raw keys" do
      html = render_html

      expect(html).to include("Thickened liquids")
      expect(html).not_to include("thickened_liquids")
      expect(html).to include("Wait and pause")
      expect(html).not_to include("wait_and_pause")
    end

    it "prints short_text answers verbatim" do
      expect(render_html).to include("hates cold food")
    end

    it "renders a custom section under its own title" do
      # One render per example — a second call would hit the freshness cache,
      # skip Grover entirely, and capture nothing.
      html = render_html

      expect(html).to include("Bedtime")
      expect(html).to include("off by seven")
    end

    # The URL moved into the identity block's QR caption when the header was
    # redesigned. It still has to be readable text: these get photocopied and
    # handed to people without a phone camera out.
    #
    # It prints the PERMANENT address, matching the QR beside it — a care plan
    # sits in a school folder for a year, so it must survive the owner changing
    # or revoking their public link (#774).
    it "prints the permanent URL as text in the identity block" do
      html = render_html

      expect(html).to include(profile.permanent_url)
      expect(html).not_to include(profile.public_url)
    end

    # The sheet lives in a folder for a school year — a printed date only makes
    # a still-current plan look stale, so nothing on it says "Prepared ...".
    it "prints no prepared-on date" do
      html = render_html

      expect(html).not_to include("Prepared")
      expect(html).not_to include(I18n.l(Date.current, format: :long))
    end

    # The redesign: a cream identity card (not a gradient band) and the care
    # sections as coloured cards in two newspaper columns.
    it "renders the identity card and flows the care sections into columns" do
      html = render_html

      expect(html).to include(%(class="identity"))
      expect(html).not_to include(%(class="band"))
      expect(html).not_to include(%(class="masthead"))
      expect(html).to include(%(class="cols"))
      expect(html).to include("column-count: 2")
    end

    # The frame is a position:fixed layer so Chrome repeats it per sheet. Its
    # inset must stay 0 — a negative one is clipped to the page content box and
    # the frame then paints on no page at all, which looks like the CSS was
    # ignored rather than like a bug.
    it "carries a page frame pinned to the page content box" do
      html = render_html

      expect(html).to include(%(class="page-frame"))
      expect(html).to match(/\.page-frame\s*\{[^}]*position:\s*fixed/m)
      expect(html).to match(/\.page-frame\s*\{[^}]*inset:\s*0/m)
    end

    # A small "Care & Emergency Plan" document-type label sits above the name
    # in the approved redesign — that's a description of the document, not
    # brand self-promotion, so it doesn't reintroduce the "SpeakAnyWay"
    # eyebrow LAYOUT_VERSION 3 removed. The mark still signs the sheet only in
    # the footnote.
    it "labels the document type above the name, with no SpeakAnyWay brand text in the identity block" do
      html = render_html

      text = identity_text(html)
      expect(text).not_to include("SpeakAnyWay")
      expect(text).to include("Rosa")
      expect(text.first).to eq("Care & Emergency Plan")
    end

    # Called out specifically in review: inline with the <h1>, a pronoun chip
    # shares its optical baseline and reads like a suffix.
    it "renders the pronoun chip on its own line under the name" do
      profile.update!(settings: profile.settings.merge("pronouns" => "he/him"))

      html = render_html

      expect(html).to match(%r{</h1>\s*<div><span class="pronoun">he/him</span></div>}m)
    end

    it "signs the document with the logo in the footnote" do
      html = render_html

      expect(html).to include(%(<img class="mark" src="data:image/png;base64,))
      # Below the care sections, not up in the identity card — on a gradient
      # the mark shares its own hues and needs a white pad to survive; down
      # here on white it needs nothing.
      expect(html.index(%(class="mark"))).to be > html.index(%(class="identity"))
    end

    # .section-keep and its heading-welding are gone; a whole section card is
    # atomic now. A stray wrapper left behind would silently defeat
    # break-inside.
    it "keeps no section-keep wrapper" do
      expect(render_html).not_to include("section-keep")
    end

    # The hierarchy fix: a picked (multi_select) set is one chip per value,
    # tinted to its section's colour, not a comma-joined sentence.
    it "renders multi-select values as chips, tinted to the section colour" do
      html = render_html

      expect(html).to include(%(<span class="chip">AAC device</span>))
      expect(html).to include(%(<span class="chip">Eye gaze</span>))
      expect(html).to include(%(class="card s-comm"))
    end

    # The layout's no-network rule. A font or image fetched mid-render fails
    # silently into a fallback and nobody notices until it ships. Icons are
    # inline SVG for the same reason.
    it "fetches nothing over the network at render time" do
      html = render_html

      expect(html).not_to include("fonts.googleapis.com")
      expect(html).not_to match(/<link[^>]+href=["']http/)
      expect(html).not_to match(/<img[^>]+src=["']http/)
    end
  end

  describe "Grover options" do
    # The mirror image of asset_pdf_page_size_spec.rb, which pins the CARD path
    # to a fixed pixel page. This document flows, so a fixed height would
    # silently discard everything past page one.
    it "renders a flowing Letter page, not a fixed pixel one" do
      opts = grover_options

      expect(opts[:format]).to eq("Letter")
      expect(opts[:prefer_css_page_size]).to be(true)
      expect(opts).not_to have_key(:width)
      expect(opts).not_to have_key(:height)
    end

    # Chrome renders header/footer in a separate document and clips them to
    # nothing unless the page reserves margin. A zero bottom margin makes the
    # page numbers vanish with no error, which is why this is pinned rather
    # than eyeballed.
    it "reserves a non-zero bottom margin so the footer can render" do
      opts = grover_options

      expect(opts[:display_header_footer]).to be(true)
      expect(opts[:margin][:bottom]).to be_present
      expect(opts[:margin][:bottom]).not_to eq("0")
      # Without an explicit (even empty) header, Chrome prints its own
      # title-and-date header.
      expect(opts[:header_template]).to be_present
    end

    it "numbers the pages and names the communicator in the footer" do
      opts = grover_options

      expect(opts[:footer_template]).to include("pageNumber")
      expect(opts[:footer_template]).to include("totalPages")
      expect(opts[:footer_template]).to include("Rosa")
    end

    it "escapes the communicator name in the footer" do
      account.update!(name: %(Ro"><script>alert(1)</script>sa))

      expect(grover_options[:footer_template]).not_to include("<script>")
    end

    # A folded card gets no page numbers, and margin: 0 is what lets the half
    # and wallet CSS lay content out against the full, untrimmed page — the
    # fold and cut lines are measured from the physical edge.
    it "renders half and wallet with no header/footer and zero margin" do
      %i[half wallet].each do |size|
        opts = grover_options(size: size)

        expect(opts[:display_header_footer]).to be(false)
        expect(opts[:margin]).to eq(0)
        expect(opts).not_to have_key(:footer_template)
      end
    end
  end

  describe "freshness" do
    it "does not re-render when nothing has changed" do
      render_html

      expect(Grover).not_to receive(:new)
      described_class.call(profile.reload, variant: :full)
    end

    # Regression: the signature used to include profile.updated_at, and
    # ActiveStorage's attachment `belongs_to :record, touch: true` — so the
    # attach that STORED the signature also moved the value the signature was
    # built from. The cached document was stale the instant it was written and
    # every later call re-rendered through headless Chrome. It read as a flaky
    # spec rather than a dead cache only because the value was truncated to
    # whole seconds: a generate finishing inside the same second as the
    # previous save happened to match, and a slower machine didn't.
    #
    # The touch is simulated in a later second so the assertion doesn't depend
    # on how long a render takes.
    it "survives the touch that attaching the document performs" do
      render_html

      travel_to(3.seconds.from_now) { profile.touch }

      expect(Grover).not_to receive(:new)
      described_class.call(profile.reload, variant: :full)
    end

    it "re-renders when regenerate is asked for" do
      render_html

      expect_rerender
      described_class.call(profile.reload, variant: :full, regenerate: true)
    end

    it "re-renders after a care answer changes" do
      render_html
      profile.update!(settings: profile.settings.deep_merge(
        "care" => { "sections" => { "meals" => { "values" => { "preferences" => "loves soup" } } } },
      ))

      expect_rerender
      described_class.call(profile.reload, variant: :full)
    end

    # safety_info_signature only moves when the PROFILE changes, so without a
    # layout version a template redesign leaves every cached PDF stale forever.
    it "re-renders when the layout version is bumped" do
      render_html
      stub_const("#{described_class}::LAYOUT_VERSION", 99)

      expect_rerender
      described_class.call(profile.reload, variant: :full)
    end

    # The two variants live in separate attachments so they cannot literally
    # collide, but a mistake that crossed them would serve a care-only download
    # containing medications. Cheap insurance.
    it "gives the two variants different signatures" do
      render_html(variant: :full)
      render_html(variant: :care_only)

      full = profile.reload.care_emergency_plan_pdf.metadata["signature"]
      care_only = profile.care_plan_pdf.metadata["signature"]

      expect(full).not_to eq(care_only)
    end

    # A signature that ignored size would serve a wallet card to someone who
    # asked for a sheet.
    it "gives different sizes different signatures, and different attachments" do
      render_html(variant: :full, size: :sheet)
      render_html(variant: :full, size: :half)

      sheet_sig = profile.reload.care_emergency_plan_pdf.metadata["signature"]
      half_sig = profile.care_emergency_plan_half_pdf.metadata["signature"]

      expect(sheet_sig).not_to eq(half_sig)
      expect(profile.care_emergency_plan_pdf).to be_attached
      expect(profile.care_emergency_plan_half_pdf).to be_attached
    end
  end

  # The line under the communicator's name. A per-download choice, not stored
  # data: the words come from `subheader`, `include_subheader: false` drops the
  # line, and blank or absent means the default copy — which is resolved from
  # the locale files at render time and never written anywhere.
  describe "the subheader" do
    def subheader_line(html)
      document_body(html)[%r{<div class="says">\s*(.*?)\s*</div>}m, 1]
    end

    it "prints the default copy when the caller asks for nothing" do
      expect(subheader_line(render_html)).to eq(CGI.escapeHTML(I18n.t("care.document.subheader.default")))
    end

    it "prints the caller's own words instead" do
      html = render_html(subheader: "Please talk to me, not about me.")

      expect(subheader_line(html)).to eq("Please talk to me, not about me.")
      expect(html).not_to include(I18n.t("care.document.subheader.default"))
    end

    it "treats a blank subheader as no answer, not as an empty line" do
      expect(subheader_line(render_html(subheader: "   ")))
        .to eq(CGI.escapeHTML(I18n.t("care.document.subheader.default")))
    end

    it "caps the caller's words" do
      html = render_html(subheader: "z" * (described_class::SUBHEADER_MAX_CHARS + 40))

      expect(subheader_line(html).length).to eq(described_class::SUBHEADER_MAX_CHARS)
    end

    it "prints no line at all when the caller turns it off" do
      html = render_html(include_subheader: false)

      expect(document_body(html)).not_to include(%(class="says"))
      expect(html).not_to include(I18n.t("care.document.subheader.default"))
    end

    it "renders on the half size too, and not on the wallet" do
      expect(document_body(render_html(size: :half))).to include(%(class="says"))
      expect(document_body(render_html(size: :wallet))).not_to include(%(class="says"))
    end

    # The identity block used to open with "I communicate using AAC device and
    # gestures…", restating the "How I talk" glance cell a centimetre below it.
    # (The cell and the Communication card still both name the method — a
    # summary strip over its own section is the design; an identity line over
    # that summary was the duplication.)
    it "does not restate the communication section" do
      html = render_html

      expect(html).not_to include("I communicate using")
      expect(identity_text(html).join(" ")).not_to include("AAC device")
    end

    # Same trap `sections` has: there is one attachment per [variant, size], so
    # a choice that misses the signature is answered by the cached document and
    # the control appears to do nothing.
    it "re-renders when the words change" do
      render_html(subheader: "One")

      expect_rerender
      described_class.call(profile.reload, variant: :full, subheader: "Two")
    end

    it "re-renders when the line is turned off" do
      render_html

      expect_rerender
      described_class.call(profile.reload, variant: :full, include_subheader: false)
    end

    it "does not re-render for the same words" do
      render_html(subheader: "One")

      expect(Grover).not_to receive(:new)
      described_class.call(profile.reload, variant: :full, subheader: "One")
    end

    # Taking the default must leave the signature exactly as it was, or the
    # option invalidates every document already generated for no change in
    # output — the same rule the sections term follows.
    it "adds no signature term when the caller takes the default" do
      render_html

      expect(profile.reload.care_emergency_plan_pdf.metadata["signature"]).not_to include("subheader")
    end
  end

  # The section picker. `sections` is an allowlist; nil means all of them, and
  # the selection has to reach the freshness signature or a narrowed download is
  # answered by the cached full document.
  describe "a narrowed selection" do
    it "prints only the selected sections" do
      html = render_html(sections: %w[meals])

      expect(html).to include("hates cold food")
      expect(html).not_to include("Bedtime")
      expect(html).not_to include("Eye gaze")
    end

    it "keeps the emergency block on the full variant" do
      html = render_html(sections: %w[meals])

      expect(html).to include("zzpeanutszz")
    end

    # An emergency-only sheet is a real request, and the reason [] can't be
    # normalized into nil anywhere along the way.
    it "prints the emergency page alone when no section is selected" do
      html = render_html(sections: [])

      expect(html).to include("zzpeanutszz")
      expect(html).not_to include("hates cold food")
      expect(html).not_to include("Bedtime")
    end

    it "re-renders when the selection changes" do
      render_html(sections: %w[meals])

      expect_rerender
      described_class.call(profile.reload, variant: :full, sections: %w[communication])
    end

    it "does not re-render for the same selection" do
      render_html(sections: %w[meals])

      expect(Grover).not_to receive(:new)
      described_class.call(profile.reload, variant: :full, sections: %w[meals])
    end

    # Order is not part of the request — it is the owner's stored order that
    # decides the sheet — so two spellings of one selection are one document.
    it "treats a reordered selection as the same document" do
      render_html(sections: %w[meals communication])

      expect(Grover).not_to receive(:new)
      described_class.call(profile.reload, variant: :full, sections: %w[communication meals])
    end

    # Every document generated before the picker shipped carries a signature
    # with no sections term. Adding one unconditionally would invalidate all of
    # them at once for no change in output.
    it "leaves the signature untouched when nothing is selected away" do
      render_html
      unfiltered = profile.reload.care_emergency_plan_pdf.metadata["signature"]

      expect(Grover).not_to receive(:new)
      described_class.call(profile.reload, variant: :full, sections: nil)
      expect(profile.reload.care_emergency_plan_pdf.metadata["signature"]).to eq(unfiltered)
    end

    it "is not printable for care-only when the selection resolves to nothing" do
      expect(described_class.printable?(profile.reload, variant: :care_only, sections: [])).to be(false)
      expect(described_class.printable?(profile.reload, variant: :care_only, sections: %w[meals])).to be(true)
    end

    # The emergency page carries the full variant on its own.
    it "is still printable for full when the selection resolves to nothing" do
      expect(described_class.printable?(profile.reload, variant: :full, sections: [])).to be(true)
    end
  end

  describe ".printable?" do
    it "is true for care-only when there are care sections" do
      expect(described_class.printable?(profile.reload, variant: :care_only)).to be(true)
    end

    it "is false for care-only when there are none" do
      profile.update!(settings: emergency)

      expect(described_class.printable?(profile.reload, variant: :care_only)).to be(false)
    end

    # The combined plan is still worth printing on emergency info alone.
    it "is true for full when there is emergency info but no care info" do
      profile.update!(settings: emergency)

      expect(described_class.printable?(profile.reload, variant: :full)).to be(true)
    end

    it "is false for full when there is neither" do
      profile.update!(settings: {})

      expect(described_class.printable?(profile.reload, variant: :full)).to be(false)
    end
  end

  describe ".supported?" do
    it "offers every size for the full variant" do
      expect(described_class.supported?("full", "sheet")).to be(true)
      expect(described_class.supported?("full", "half")).to be(true)
      expect(described_class.supported?("full", "wallet")).to be(true)
    end

    it "does not offer wallet for care_only" do
      expect(described_class.supported?("care_only", "wallet")).to be(false)
    end

    it "is false, not a raise, for an unknown variant" do
      expect(described_class.supported?("everything", "sheet")).to be(false)
    end
  end

  # The half and wallet sizes are fixed single pages with overflow: hidden —
  # a maxed-out profile WILL silently clip unless the overflow ladder kicks in.
  # There is no headless Chrome at spec time to actually paginate against, so
  # this pins the deterministic proxy (CarePlanDocument#half_condensed? /
  # #half_truncated?) rather than a rendered page count.
  describe "the half and wallet sizes" do
    it "renders the half size as two panels with a fold rule between them" do
      html = render_html(variant: :full, size: :half)

      expect(html).to include(%(class="foldsheet"))
      expect(html).to include(%(class="fpanel flip"))
      expect(html).to include("Fold here")
    end

    it "does not condense a sparse profile's half size" do
      html = render_html(variant: :full, size: :half)

      expect(html).to include(%(class="chip">AAC device</span>))
      expect(html).not_to include("Full plan on my live page")
    end

    it "condenses and truncates a maxed-out profile's half size, pointing to the live page" do
      profile.update_columns(settings: maxed_out_care_settings)

      html = render_html(variant: :full, size: :half)

      expect(html).not_to include(%(class="chip"))
      expect(html).to include("Full plan on my live page")
    end

    it "renders four identical wallet strips, each capped at the wallet line limit" do
      html = render_html(variant: :full, size: :wallet)

      expect(html.scan(%(class="wstrip")).length).to eq(4)
      lines_per_strip = html.scan(%(class="li")).length / 4
      expect(lines_per_strip).to be <= described_class::WALLET_LINE_LIMIT
    end

    # One subject per face: the front is who this is and who to call, the back
    # is day-to-day support. The contacts used to print on the BACK with a
    # one-line "Call first" repeat of the top one squeezed onto the front.
    it "prints the wallet's contacts on the front face and the care lines on the back" do
      strips = wallet_strips(render_html(variant: :full, size: :wallet))

      expect(strips.length).to eq(4)

      strips.each do |back, front|
        expect(front).to include("zzSamzz").and include("555-0100")
        expect(front).not_to include(%(class="li"))
        expect(back).to include(%(class="li"))
        expect(back).not_to include("555-0100")
      end
    end

    it "caps each wallet line's length as well as the number of lines" do
      profile.update_columns(settings: maxed_out_care_settings)

      html = render_html(variant: :full, size: :wallet)

      values = html.scan(%r{<span class="v">([^<]*)</span>}).flatten
      expect(values).to be_present
      expect(values.map(&:length).max).to be <= described_class::WALLET_LINE_MAX_CHARS
    end

    # Same trap on the half size's last-resort tier: the LINE COUNT bounds
    # nothing when one maxed-out section joins to hundreds of characters and
    # wraps to four visual lines on its own, and the panel clips in silence.
    it "caps each line's length in the half size's truncated tier too" do
      profile.update_columns(settings: maxed_out_care_settings)

      html = render_html(variant: :full, size: :half)

      values = html.scan(%r{<span class="v">\s*([^<]*?)\s*</span>}).flatten
      expect(values).to be_present
      expect(values.map(&:length).max).to be <= described_class::HALF_TRUNCATED_LINE_MAX_CHARS
    end

    it "condenses the wallet size the same way for a maxed-out profile" do
      profile.update_columns(settings: maxed_out_care_settings)

      html = render_html(variant: :full, size: :wallet)

      expect(html).to include(%(class="wstrip"))
      lines_per_strip = html.scan(%(class="li")).length / 4
      expect(lines_per_strip).to be <= described_class::WALLET_LINE_LIMIT
    end
  end

  # An ampersand a parent typed used to be PERSISTED escaped, so the printed
  # sheet said "hugs &amp; quiet spaces" in the reader's hands. The template
  # escapes on output like any ERB tag, so the fix is stored text carrying the
  # raw character — which means the HTML holds exactly one level of escaping.
  describe "an ampersand in care text" do
    before do
      profile.update!(
        settings: {
          "care" => {
            "sections" => {
              "sensory" => { "values" => { "calming" => "Loves hugs & quiet spaces" } },
              "c_7f3a91" => {
                "custom" => true,
                "title" => "Snacks & drinks",
                "items" => [{ "label" => "Cups & lids", "value" => "Green & blue only" }],
              },
            },
          },
        },
      )
    end

    it "prints as a literal ampersand, not an entity" do
      html = render_html(variant: :care_only)

      expect(html).to include("Loves hugs &amp; quiet spaces")
      expect(html).to include("Snacks &amp; drinks")
      expect(html).to include("Green &amp; blue only")
      # The bug's signature: a second level of escaping, which renders as the
      # visible text "&amp;".
      expect(html).not_to include("&amp;amp;")
    end
  end

  it "refuses an unknown variant" do
    expect { described_class.call(profile, variant: :everything) }
      .to raise_error(described_class::UnknownVariant)
  end

  it "refuses an unsupported [variant, size] pair" do
    expect { described_class.call(profile, variant: :care_only, size: :wallet) }
      .to raise_error(described_class::UnsupportedSize)
  end

  # The thumbnail the Print & share tab shows beside each Download button.
  describe "the preview thumbnail" do
    # Every supported pair, so a size added without a `preview:` key fails here
    # rather than shipping a card that shows a placeholder forever.
    described_class::VARIANTS.each do |variant, variant_config|
      variant_config[:sizes].each do |size, size_config|
        it "attaches a PNG for #{variant}/#{size}" do
          render_html(variant: variant, size: size)

          preview = profile.reload.public_send(size_config[:preview])
          expect(preview).to be_attached
          expect(preview.content_type).to eq("image/png")
          expect(preview.filename.to_s).to end_with("-preview.png")
        end
      end
    end

    it "renders the thumbnail from the same HTML as the PDF, rendering the ERB once" do
      seen = []
      allow(Grover).to receive(:new) do |html, **_opts|
        seen << html
        grover_double
      end

      described_class.call(profile.reload, variant: :full)

      expect(seen.length).to eq(2)
      expect(seen.uniq.length).to eq(1)
    end

    it "rasterizes at Letter proportions" do
      opts = preview_grover_options

      expect(opts[:format]).to eq("png")
      expect(opts[:viewport]).to eq(
        { width: described_class::PREVIEW_WIDTH, height: described_class::PREVIEW_HEIGHT },
      )
      # 8.5 x 11in. A thumbnail at any other ratio is a crop of the page, not a
      # picture of it.
      expect(described_class::PREVIEW_WIDTH.to_f / described_class::PREVIEW_HEIGHT).to be_within(0.001).of(8.5 / 11)
    end

    it "shares the document's freshness signature" do
      render_html

      profile.reload
      expect(profile.care_emergency_plan_preview_png.metadata["signature"])
        .to eq(profile.care_emergency_plan_pdf.metadata["signature"])
    end

    it "is not re-rendered when the document is already fresh" do
      render_html

      expect(Grover).not_to receive(:new)
      described_class.call(profile.reload, variant: :full)
    end

    # The reason no LAYOUT_VERSION bump ships with previews: a document cached
    # before they existed is otherwise "fresh" forever, so the download keeps
    # working while the thumbnail beside it stays a placeholder with no way for
    # the owner to force one. Simulated by purging the preview and leaving the
    # PDF and its signature exactly as they were.
    it "is backfilled onto a document cached before previews existed" do
      render_html
      profile.reload.care_emergency_plan_preview_png.purge
      pdf_signature = profile.reload.care_emergency_plan_pdf.metadata["signature"]

      described_class.call(profile.reload, variant: :full)

      profile.reload
      expect(profile.care_emergency_plan_preview_png).to be_attached
      expect(profile.care_emergency_plan_pdf.metadata["signature"]).to eq(pdf_signature)
    end

    # Each pair has its own preview, for the same reason each has its own PDF:
    # the picker switches between them and a shared thumbnail would show the
    # wrong document.
    it "keeps each size's thumbnail separate" do
      render_html(variant: :full, size: :sheet)
      render_html(variant: :full, size: :wallet)

      profile.reload
      expect(profile.care_emergency_plan_preview_png).to be_attached
      expect(profile.care_emergency_plan_wallet_preview_png).to be_attached
      expect(profile.care_emergency_plan_preview_png.metadata["signature"])
        .not_to eq(profile.care_emergency_plan_wallet_preview_png.metadata["signature"])
    end
  end
end
