# frozen_string_literal: true

# Turns a BoardPrintable's stored listing copy into paste-ready blocks for the
# marketplaces that have no API.
#
# Teachers Pay Teachers is the reason this exists: there is no seller API, so
# the only way to list there is to type into their upload form. Rather than
# make someone re-derive the copy by hand, this lays it out field by field in
# the order the form asks for it.
#
# Every field is `{ label:, value:, hint: }` so the view can render the list
# without knowing anything about TPT.
module Printables
  class MarketplaceCopy
    Field = Struct.new(:label, :value, :hint, keyword_init: true)

    # TPT's title cap is 100, not Etsy's 140 — the generated Etsy title is
    # normally too long to paste, so it gets its own trim.
    TPT_TITLE_MAX = 100

    # TPT allows a primary subject plus two more, and up to three resource
    # types. These are the closest matches in their fixed taxonomy for an AAC
    # communication board; they are defaults, not rules.
    TPT_SUBJECTS = "Special Education, Speech Therapy, Other (Specialty)".freeze
    TPT_RESOURCE_TYPES = "Printables, Activities, Independent Work Packet".freeze
    TPT_GRADES = "PreK - 2nd".freeze

    # TPT's keyword box takes a handful of phrases, not Etsy's 13.
    TPT_KEYWORD_COUNT = 5

    def initialize(printable, listing: nil)
      @printable = printable
      # listing_copy defaults to an empty hash, which is blank — so falling back
      # to it directly would leave every field empty until someone pressed Save.
      # listing_copy_or_default is what generates the preview.
      @listing = (listing.presence || printable.listing_copy_or_default).with_indifferent_access
    end

    def tpt_fields
      [
        Field.new(label: "Product title", value: tpt_title,
                  hint: "#{tpt_title.length}/#{TPT_TITLE_MAX} characters"),
        Field.new(label: "Description", value: description,
                  hint: "Plain text — paste straight into TPT's editor"),
        Field.new(label: "Price (USD)", value: price_display, hint: nil),
        Field.new(label: "Grade levels", value: TPT_GRADES,
                  hint: "Widen it if the board's vocabulary suits older students"),
        Field.new(label: "Subjects", value: TPT_SUBJECTS,
                  hint: "Primary first; TPT allows three"),
        Field.new(label: "Resource types", value: TPT_RESOURCE_TYPES,
                  hint: "TPT allows three"),
        Field.new(label: "Number of pages", value: page_count_display, hint: nil),
        Field.new(label: "Search keywords", value: tpt_keywords,
                  hint: "Trimmed from the Etsy tag list"),
        Field.new(label: "Files to upload", value: file_list,
                  hint: "Download these from the Files section above"),
        Field.new(label: "Standards", value: "(leave blank)",
                  hint: "AAC vocabulary boards don't map cleanly to CCSS — skip rather than guess"),
      ]
    end

    def generic_fields
      [
        Field.new(label: "Title", value: title, hint: "#{title.length} characters"),
        Field.new(label: "Description", value: description, hint: nil),
        Field.new(label: "Tags", value: tags.join(", "), hint: "#{tags.size} tags"),
        Field.new(label: "Price (USD)", value: price_display, hint: nil),
      ]
    end

    def title = @listing[:title].to_s

    def description = @listing[:description].to_s

    def tags = Array(@listing[:tags]).map(&:to_s)

    def price_cents = @listing[:price_cents].presence&.to_i || Etsy::ListingCopy::DEFAULT_PRICE_CENTS

    private

    attr_reader :printable

    # The Etsy title carries "(Digital Download)" and a long keyword tail that
    # both overflow TPT's 100 and read as spam there. Drop the suffix first,
    # then trim on a word boundary rather than mid-word.
    def tpt_title
      @tpt_title ||= begin
        base = title.sub(/\s*#{Regexp.escape(Etsy::CopyRules::DIGITAL_DOWNLOAD_SUFFIX)}\s*\z/, "").strip
        base.length <= TPT_TITLE_MAX ? base : base[0, TPT_TITLE_MAX].sub(/\s+\S*\z/, "").strip
      end
    end

    def tpt_keywords = tags.first(TPT_KEYWORD_COUNT).join(", ")

    def price_display = format("%.2f", price_cents / 100.0)

    def page_count_display = printable.page_count.to_i.positive? ? printable.page_count.to_s : "—"

    def file_list
      files = printable.files_view
      return "—" if files.empty?

      files.map { |f| f[:filename] }.join("\n")
    end
  end
end
