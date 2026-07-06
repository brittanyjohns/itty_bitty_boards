# Renders generic (data-less) marketing printables on demand and streams the
# PDF, mirroring the board export endpoint's send_data shape. Currently serves
# the generic AAC Classroom name-tag sheet (variant A). The printables
# marketing-kit script fetches this, then merges it into the combined kit.
class API::Internal::MarketingArtifactsController < API::Internal::ApplicationController
  # GET /api/internal/marketing_artifacts/name_tag.pdf?qr_target_url=...&per_page=8
  def name_tag
    per_page = params[:per_page].presence
    pdf = Marketing::NameTagSheet.new(
      qr_target_url: params[:qr_target_url],
      per_page: per_page ? per_page.to_i : Marketing::NameTagSheet::DEFAULT_PER_PAGE,
    ).to_pdf

    response.headers["Cache-Control"] = "no-store"
    send_data pdf,
      filename: "aac-classroom-name-tags.pdf",
      type: "application/pdf",
      disposition: "attachment"
  end
end
