# Hosts the assembled AAC Classroom Kit PDF (and its individual artifacts) at a
# stable public slug. The printables marketing-kit script merges the per-artifact
# PDFs with pdf-lib, then POSTs the combined file here to obtain the permanent
# CDN URL used as the /classroom page's KIT_DOWNLOAD_URL.
#
# Additive, behind INTERNAL_API_KEY. Never publishes to any marketplace.
class API::Internal::MarketingAssetsController < API::Internal::ApplicationController
  # POST /api/internal/marketing_assets
  # Params: slug (required), file (required, multipart PDF), title, kind.
  def create
    slug = params[:slug].to_s.strip

    if slug.blank?
      render json: { error: "slug_required" }, status: :unprocessable_content
      return
    end

    bytes = pdf_bytes
    if bytes.blank?
      render json: { error: "file_required" }, status: :unprocessable_content
      return
    end

    asset = MarketingAsset.upsert_pdf!(
      slug: slug,
      bytes: bytes,
      title: params[:title],
      kind: params[:kind].presence || "kit",
    )

    render json: asset_json(asset), status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: "invalid_asset", details: e.record.errors.full_messages }, status: :unprocessable_content
  rescue => e
    Rails.logger.error("[Internal::MarketingAssets#create] #{e.class}: #{e.message}")
    render json: { error: "upload_failed" }, status: :unprocessable_content
  end

  # GET /api/internal/marketing_assets/:slug
  def show
    asset = MarketingAsset.find_by(slug: params[:slug])

    if asset.nil?
      render json: { error: "marketing_asset_not_found", slug: params[:slug] }, status: :not_found
      return
    end

    render json: asset_json(asset)
  end

  private

  def pdf_bytes
    file = params[:file]
    return nil if file.blank?

    if file.respond_to?(:read)
      file.read
    else
      file.to_s
    end
  end

  def asset_json(asset)
    {
      slug: asset.slug,
      title: asset.title,
      kind: asset.kind,
      url: asset.file_url,
    }
  end
end
