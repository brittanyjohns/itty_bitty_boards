# Records that this app has sent a listing video to the Etsy listing a
# printable is attached to.
#
# Needed because Etsy allows exactly ONE video per listing and this app
# implements no list or delete counterpart for them (see Etsy::Client
# #upload_video) — so it cannot look at a listing and find out whether one is
# already there. A POST is safe against a listing with no video and is the
# whole point of the push; a SECOND one has no defined outcome this app could
# check. The column is the local memory that makes the second push refusable.
#
# Deliberately not cleared by re-rendering the video: replacing a listing's
# existing video needs Etsy's `video_id` form field, which is an update call
# the drafts-only invariant keeps out. Once a listing has one, swapping it is
# a seller-UI job.
class AddEtsyVideoPushedAtToBoardPrintables < ActiveRecord::Migration[8.0]
  def change
    add_column :board_printables, :etsy_video_pushed_at, :datetime
  end
end
