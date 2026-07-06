# A hosted, print-ready marketing PDF (e.g. the assembled AAC Classroom Kit)
# addressed by a stable public slug. There is no natural parent record for the
# combined kit PDF — it is not a Board or a Profile — so this small model owns
# the attachment.
#
# The file is attached at a DETERMINISTIC S3 key (`marketing_assets/<slug>.pdf`)
# with purge-then-reupload on every regeneration, mirroring
# Boards::GeneratePreviewAssets#stable_preview_key. Production S3 is
# `public: true`, so the resulting URL is a permanent, unsigned, CDN-stable
# link that never changes across re-runs — exactly what the /classroom page's
# KIT_DOWNLOAD_URL needs. Re-running the kit build is therefore idempotent:
# same slug -> same URL, new bytes.
class MarketingAsset < ApplicationRecord
  has_one_attached :file

  SLUG_FORMAT = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

  validates :slug, presence: true, uniqueness: true, format: { with: SLUG_FORMAT }
  validates :kind, presence: true

  # Upsert an asset by slug and (re)attach the given PDF bytes at the stable key.
  def self.upsert_pdf!(slug:, bytes:, title: nil, kind: "kit")
    asset = find_or_initialize_by(slug: slug)
    asset.title = title if title.present?
    asset.kind = kind.presence || asset.kind.presence || "kit"
    asset.save!
    asset.attach_pdf!(bytes)
    asset
  end

  # Deterministic key so the public CDN URL is stable across regenerations.
  def storage_key
    "marketing_assets/#{slug}.pdf"
  end

  def attach_pdf!(bytes)
    # Purge the existing object at the deterministic key first, or
    # create_and_upload! would collide on the unique active_storage_blobs.key
    # index (same pattern as Boards::GeneratePreviewAssets#attach_png).
    file.purge if file.attached?

    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(bytes),
      filename: "#{slug}.pdf",
      content_type: "application/pdf",
      key: storage_key,
    )
    file.attach(blob)
    self
  end

  # Permanent public URL for the hosted PDF. Prefers the CloudFront CDN host
  # (like Board#pdf_url / Profile#url_for_attachment) and falls back to the
  # direct Active Storage URL. Never raises — a hosting URL must not break the
  # caller.
  def file_url
    return nil unless file.attached?

    cdn_host = ENV["CDN_HOST"]
    if cdn_host.present?
      "#{cdn_host}/#{file.key}"
    else
      file.url
    end
  rescue => e
    Rails.logger.warn("MarketingAsset#file_url failed for #{slug}: #{e.class}: #{e.message}")
    nil
  end
end
