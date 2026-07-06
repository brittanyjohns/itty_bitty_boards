# Renders generic (data-less) marketing printables on demand and streams the
# PDF, mirroring the board export endpoint's send_data shape. Serves the AAC
# Classroom Kit's generic sheets — name tags, and the compact print-and-cut
# backpack safety + device tags. The printables marketing-kit script fetches
# these, then merges them into the combined kit.
class API::Internal::MarketingArtifactsController < API::Internal::ApplicationController
  # GET /api/internal/marketing_artifacts/name_tag.pdf?qr_target_url=...&per_page=8
  def name_tag
    stream_sheet(Marketing::NameTagSheet, "aac-classroom-name-tags.pdf")
  end

  # GET /api/internal/marketing_artifacts/safety_tag.pdf?qr_target_url=...&per_page=2
  def safety_tag
    stream_sheet(Marketing::SafetyTagSheet, "aac-classroom-safety-tags.pdf")
  end

  # GET /api/internal/marketing_artifacts/device_tag.pdf?qr_target_url=...&per_page=2
  def device_tag
    stream_sheet(Marketing::DeviceTagSheet, "aac-classroom-device-tags.pdf")
  end

  private

  def stream_sheet(sheet_class, filename)
    per_page = params[:per_page].presence
    pdf = sheet_class.new(
      qr_target_url: params[:qr_target_url],
      per_page: per_page ? per_page.to_i : sheet_class::DEFAULT_PER_PAGE,
    ).to_pdf

    response.headers["Cache-Control"] = "no-store"
    send_data pdf,
      filename: filename,
      type: "application/pdf",
      disposition: "attachment"
  end
end
