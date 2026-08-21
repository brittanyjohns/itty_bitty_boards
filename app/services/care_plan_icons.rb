# frozen_string_literal: true

# Inline SVG icon paths for the care plan PDF's section cards. Stroke-only,
# 24x24 viewBox, no icon font and nothing fetched — the care plan layout's
# no-network rule (layouts/pdf_care_plan.html.erb) applies to icons too.
#
# Keyed by CarePlanDocument's per-section STYLE key (comm/care/meal/sens/
# move/trav), not the raw section key, so a custom section — which shares the
# "trav" colour and icon rather than inventing its own — resolves the same way
# a built-in one does.
module CarePlanIcons
  PATHS = {
    "comm" => '<path d="M21 11.5a8.4 8.4 0 0 1-9 8.4 9.6 9.6 0 0 1-2.9-.4L3 21l1.6-4.6A8.3 8.3 0 0 1 3 11.5 8.4 8.4 0 0 1 12 3a8.4 8.4 0 0 1 9 8.5z"/>',
    "care" => '<path d="M12 21s-7-4.4-9-9a5 5 0 0 1 9-3 5 5 0 0 1 9 3c-2 4.6-9 9-9 9z"/>',
    "meal" => '<path d="M6 3v8a2 2 0 0 0 4 0V3M8 11v10M18 3c-1.7 1.3-2.5 3-2.5 5.5 0 1.8.8 2.9 2.5 3.2V21"/>',
    "sens" => '<path d="M12 3a9 9 0 1 0 0 18h1.5a2 2 0 0 0 0-4H13a1.5 1.5 0 0 1 0-3h3.5A4.5 4.5 0 0 0 21 9.5C21 5.9 16.9 3 12 3z"/><circle cx="7.5" cy="11" r="1"/><circle cx="11" cy="7.5" r="1"/><circle cx="15.5" cy="8.5" r="1"/>',
    # Not in the visual reference (the sample profile has no mobility section)
    # — drawn to match the same stroke-only style as the rest.
    "move" => '<circle cx="8.5" cy="17" r="3.5"/><path d="M8.5 17V6.5a2 2 0 0 1 2-2H12M8.5 13h6.5l2.5 4"/><circle cx="18" cy="18.5" r="1.25"/>',
    "trav" => '<rect x="3" y="4" width="18" height="12" rx="2"/><path d="M3 10h18M7 20v-2M17 20v-2"/><circle cx="7.5" cy="13.5" r="1"/><circle cx="16.5" cy="13.5" r="1"/>',
  }.freeze

  def self.svg_for(style_key)
    PATHS.fetch(style_key, PATHS["trav"]).html_safe
  end
end
