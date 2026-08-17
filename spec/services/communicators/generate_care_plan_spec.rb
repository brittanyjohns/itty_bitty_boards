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

  # Captures the HTML handed to Grover instead of rendering a PDF.
  def render_html(variant: :full, **kwargs)
    captured = nil
    allow(Grover).to receive(:new) do |html, **_opts|
      captured = html
      instance_double(Grover, to_pdf: "%PDF-stub")
    end

    described_class.call(profile.reload, variant: variant, **kwargs)
    captured
  end

  def grover_options(variant: :full)
    captured = nil
    allow(Grover).to receive(:new) do |_html, **opts|
      captured = opts
      instance_double(Grover, to_pdf: "%PDF-stub")
    end

    described_class.call(profile.reload, variant: variant)
    captured
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
      # layout comment, and the label is what costs a row.
      expect(html).to include(%(<span class="k">Allergies</span>))
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

    # The URL moved out from under the QR into the band's meta line when the
    # header was condensed. It still has to be readable text: these get
    # photocopied and handed to people without a phone camera out.
    it "prints the public URL as text in the header band" do
      expect(render_html).to include(profile.public_url)
    end

    # The sheet lives in a folder for a school year — a printed date only makes
    # a still-current plan look stale, so the band carries no "Prepared ...".
    it "prints no prepared-on date" do
      html = render_html

      expect(html).not_to include("Prepared")
      expect(html).not_to include(I18n.l(Date.current, format: :long))
    end

    # The density change, pinned: one gradient band instead of masthead +
    # identity, and the care sections in two newspaper columns.
    it "renders one header band and flows the care sections into columns" do
      html = render_html

      expect(html).to include(%(class="band"))
      expect(html).not_to include(%(class="masthead"))
      expect(html).not_to include(%(class="identity"))
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

    it "signs the document with the logo in the footnote" do
      html = render_html

      expect(html).to include(%(<img class="mark" src="data:image/png;base64,))
      # Below the care sections, not up in the band — on the gradient the mark
      # shares its own hues and needs a white pad to survive.
      expect(html.index(%(class="mark"))).to be > html.index(%(class="band"))
    end

    # .section-keep and its heading-welding are gone; a whole section is atomic
    # now. A stray wrapper left behind would silently defeat break-inside.
    it "keeps no section-keep wrapper" do
      expect(render_html).not_to include("section-keep")
    end

    it "joins multi-select values as text rather than chips" do
      html = render_html

      expect(html).to include("AAC device, Eye gaze")
      expect(html).not_to include(%(class="chip"))
    end

    # The layout's no-network rule. A font or image fetched mid-render fails
    # silently into a fallback and nobody notices until it ships.
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

      expect(Grover).to receive(:new).and_return(instance_double(Grover, to_pdf: "%PDF-stub"))
      described_class.call(profile.reload, variant: :full, regenerate: true)
    end

    it "re-renders after a care answer changes" do
      render_html
      profile.update!(settings: profile.settings.deep_merge(
        "care" => { "sections" => { "meals" => { "values" => { "preferences" => "loves soup" } } } },
      ))

      expect(Grover).to receive(:new).and_return(instance_double(Grover, to_pdf: "%PDF-stub"))
      described_class.call(profile.reload, variant: :full)
    end

    # safety_info_signature only moves when the PROFILE changes, so without a
    # layout version a template redesign leaves every cached PDF stale forever.
    it "re-renders when the layout version is bumped" do
      render_html
      stub_const("#{described_class}::LAYOUT_VERSION", 99)

      expect(Grover).to receive(:new).and_return(instance_double(Grover, to_pdf: "%PDF-stub"))
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

  it "refuses an unknown variant" do
    expect { described_class.call(profile, variant: :everything) }
      .to raise_error(described_class::UnknownVariant)
  end
end
