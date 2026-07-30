# app/services/images/license_resolution.rb
#
# The single place that knows where a license lives on a Doc and how to
# normalize it. Extracted from Images::CommercialLicense so the export
# predicate (Images::RedistributionLicense) reads licenses the same way.
#
# Grounded in the actual library (measured 2026-07-22, 10,101 docs). Two facts
# drive the shape of this code:
#
#   * Doc#license is the ONLY populated license field (Image#license has zero
#     rows) and its jsonb key is "type", not "license".
#   * Doc#license is populated only on ObfImport docs. OpenSymbol-sourced docs
#     carry their license on the OpenSymbol row instead.
module Images
  module LicenseResolution
    module_function

    # OpenSymbol docs keep their license on the symbol row, not the doc.
    # search_string has no uniqueness constraint and is a label match, NOT
    # provenance — more than one symbol can share it with different licenses
    # (e.g. "family - family, ,": one CC BY-SA, one public domain). We cannot
    # know which symbol this doc actually came from, so only trust the license
    # when every matching row agrees (after normalization); otherwise treat the
    # doc as having no usable license, which callers render as unsafe.
    #
    # Returns the jsonb hash, a license string, :protected, or nil.
    def resolve(doc)
      return doc.license if doc.license.present?
      return nil unless doc.source_type == "OpenSymbol"

      symbols = doc.matching_open_symbols.order(:id).to_a
      return nil if symbols.empty?
      return :protected if symbols.any? { |symbol| truthy?(symbol.protected_symbol) }

      normalized_licenses = symbols.map { |symbol| normalize_type(symbol.license) }.uniq
      return nil unless normalized_licenses.size == 1

      symbols.first.license
    end

    # "CC By-SA 3.0" -> "cc by-sa 3.0"; collapses whitespace so version
    # suffixes and casing inconsistencies in the library don't matter.
    def normalize_type(value)
      value.to_s.strip.downcase.gsub(/\s+/, " ")
    end

    def truthy?(value)
      ["true", "t", "1", true].include?(value.is_a?(String) ? value.downcase : value)
    end
  end
end
