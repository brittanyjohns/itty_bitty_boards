# The two URLs every buyer-facing attachment carries, and why there are two.
#
# `url_for_file` PREVIEWS (the cached CDN link every browser opens inline) and
# `download_url_for_file` SAVES (presigned, carrying Content-Disposition). Both
# are needed because our CDN sends no disposition header and neither frontend
# workaround applies: an anchor's `download` attribute is ignored cross-origin,
# and fetch+blob dies on CORS.
#
# Extracted from BoardPrintable when KitPage grew its own uploaded documents —
# the presign path below is subtle enough that a second copy would drift.
module AttachedFileUrls
  extend ActiveSupport::Concern

  # How long a presigned download link stays valid. Generous because the link is
  # handed to a visitor who may sit on a success card before clicking it; the
  # object is public either way (see #url_for_file), so the signature buys the
  # Content-Disposition header, not secrecy.
  DOWNLOAD_URL_EXPIRES_IN = 24.hours

  private

  # Production S3 is `public: true`, so the URL is CDN_HOST + key rather than
  # a presigned one — same convention as Board#pdf_url and
  # MarketingAsset#file_url. Never raises: a download URL must not break the
  # status response.
  def url_for_file(file)
    cdn_host = ENV["CDN_HOST"]
    return "#{cdn_host}/#{file.key}" if cdn_host.present?

    file.url
  rescue => e
    Rails.logger.warn("#{self.class.name}#url_for_file failed for #{id}: #{e.class}: #{e.message}")
    nil
  end

  # The "save this file" twin of #url_for_file. The CDN serves these PDFs with
  # no Content-Disposition, so a browser INLINES them — which is what made the
  # /kit/:slug Download button open a viewer tab instead of downloading. Neither
  # frontend fix applies: an anchor's `download` attribute is ignored
  # cross-origin, and fetch+blob dies because the CDN has no CORS rule for our
  # origins.
  #
  # So the header has to come from S3, and it can only come from a PRESIGNED
  # request — `public: true` on the service makes ActiveStorage's own
  # `file.url(disposition:)` return a bare public URL with the disposition
  # dropped. This deliberately addresses the bucket rather than CDN_HOST:
  # CloudFront ignores query strings (see
  # BoardPrintable#versioned_storage_key_for), so a response-content-disposition
  # override sent through it would never reach S3.
  #
  # Never raises, same contract as #url_for_file — nil simply means the caller
  # falls back to the preview URL.
  def download_url_for_file(file)
    service = file.blob.service
    # Disk (development and test) honours disposition through the normal URL
    # builder, and has no bucket to presign against.
    unless service.respond_to?(:bucket) && service.bucket
      return file.url(disposition: :attachment)
    end

    # Mirrors ActiveStorage::Service::S3Service#private_url, which is the code
    # path a non-public service would have taken.
    service.bucket.object(file.key).presigned_url(
      :get,
      expires_in: DOWNLOAD_URL_EXPIRES_IN.to_i,
      response_content_disposition: ActionDispatch::Http::ContentDisposition.format(
        disposition: "attachment",
        filename: file.filename.sanitized,
      ),
    )
  rescue => e
    Rails.logger.warn("#{self.class.name}#download_url_for_file failed for #{id}: #{e.class}: #{e.message}")
    nil
  end
end
