# One Etsy listing made from a BoardPrintable.
#
# A printable can carry several — a standalone listing and a bundle listing, say
# — each with its own copy, its own gallery selection and its own PDF subset,
# all serving the same rendered document. Before this existed the listing WAS
# four scalar columns on `board_printables`, so a printable could hold one
# listing at a time and reaching a second one meant NULLing the first.
#
# Two things this row is, that the columns could not be:
#
#   * A publish TOKEN. The row is created `pending`, before anything touches
#     Etsy, and a compare-and-set on `state` claims it exactly once. That is how
#     a double-click, a double-enqueue or a hand-run Sidekiq retry are stopped
#     from creating a second draft in a real shop.
#   * A permanent RECORD. Detaching supersedes the row and KEEPS the listing id,
#     because this app implements no delete call — the draft is still on Etsy
#     and someone has to be told which one to go and remove.
class BoardPrintableListing < ApplicationRecord
  # pending    — allocated, nothing sent to Etsy yet. Deletable.
  # publishing — claimed by a job. Only the job may move it off this.
  # published  — a draft exists on Etsy. `etsy_listing_id` is set.
  # failed     — the publish stopped before `create_listing` returned. Nothing
  #              was created; the same claim accepts a retry.
  # superseded — detached. The id is kept; the draft is still on Etsy.
  STATES = %w[pending publishing published failed superseded].freeze

  # Free text lives in `label`; this is only the coarse kind, so the admin list
  # can be read at a glance.
  PURPOSES = %w[standalone bundle variant].freeze

  belongs_to :board_printable
  belongs_to :created_by, class_name: "User", optional: true

  validates :state, inclusion: { in: STATES }
  validates :purpose, inclusion: { in: PURPOSES }

  scope :ordered, -> { order(:created_at, :id) }

  # The rows that have touched Etsy. Deliberately a UNION of the two columns and
  # deliberately NOT filtered on `superseded_at` — this is what marketplace
  # protection reads, and a detached listing still protects: ending or replacing
  # a listing does not un-print the paper carrying these boards' QR codes.
  scope :reached_etsy, -> { where("etsy_listing_id IS NOT NULL OR published_at IS NOT NULL") }

  # A draft exists on Etsy for THIS row. The single thing that refuses a second
  # publish of the same row — the duty BoardPrintable#etsy_published? used to
  # carry for the whole printable.
  def reached_etsy? = etsy_listing_id.present? || published_at.present?

  # Attached to a live listing right now: a draft exists and nobody detached it.
  def attached? = etsy_listing_id.present? && superseded_at.nil?

  def superseded? = superseded_at.present?

  # The draft exists but not everything reached it. Distinguishable only because
  # the id is persisted the instant Etsy returns it, before any upload — which
  # is what stops a half-built draft becoming an orphan.
  def assets_incomplete? = published_at.present? && assets_uploaded_at.nil?

  # Overrides merged over the printable's base copy. Blank values fall back
  # rather than publishing an empty title, so clearing a field in the form means
  # "use the printable's" and not "send nothing".
  def resolved_copy
    board_printable.listing_copy_or_default.to_h.stringify_keys
                   .merge(listing_copy.to_h.stringify_keys.compact_blank)
  end

  # Feeds the gallery renderer, which builds its slides from the boards and the
  # topic — never from `listing_copy`. Overriding the topic is the only lever
  # that makes two listings of one printable render different images.
  def resolved_topic = topic_override.presence || board_printable.topic

  # Etsy allows one video per listing and this app implements no call that can
  # read a listing back, so this stamp is the only memory that makes a second
  # POST at the SAME listing refusable. It is per row because the rule is per
  # listing: the same clip going to a standalone and a bundle is correct.
  def can_push_video? = attached? && video_pushed_at.nil?

  def mark_video_pushed!
    update_columns(video_pushed_at: Time.current, updated_at: Time.current)
  end

  # Detach WITHOUT forgetting.
  #
  # Keeps `etsy_listing_id` so the admin can still be told which draft to delete
  # on Etsy — the old #relist! NULLed it and left the draft unfindable. Keeps
  # `video_pushed_at` too: that was true of THIS listing, and a replacement is a
  # different row whose stamp is nil by construction.
  def supersede!
    update!(state: "superseded", superseded_at: Time.current)
  end
end
