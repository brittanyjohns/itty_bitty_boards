module Admin
  module BoardPrintablesHelper
    def board_printable_status_badge(status)
      case status
      when "complete"   then "bg-green-900/60 text-green-300"
      when "generating" then "bg-indigo-900/60 text-indigo-300"
      when "pending"     then "bg-amber-900/60 text-amber-300"
      when "failed"      then "bg-red-900/60 text-red-300"
      else "admin-card-alt text-t2"
      end
    end

    # Same key the printable's cover QR uses, so the link an admin opens is the
    # page the printed board points at.
    def board_public_page_url(board)
      base_url = ENV["FRONT_END_URL"] || "http://localhost:8100"
      "#{base_url}/pb/#{Boards::Printables::CollectPages.qr_key_for(board)}"
    end

    # The SELLER's listing editor, not the public listing page. Rails only ever
    # creates drafts (see Etsy::Client#create_listing), and a draft has no public
    # page — `etsy.com/listing/:id` is a dead end until someone activates it,
    # which is exactly the click this link exists to lead up to. The `#media`
    # fragment opens on the photos section, where the gallery images this app
    # uploaded are what an admin is checking before going live.
    #
    # Built from the numeric listing id rather than the stored
    # `etsy_listing_url`, even though we have the URL Etsy handed back.
    # `etsy_listing_url` is a string column, so a link_to href reading it is an
    # XSS sink as far as any analysis can tell — the fact that only Etsy's API
    # response ever writes it isn't visible at the call site, and wouldn't stay
    # true if something else started writing the column. The id is a bigint, so
    # there is nothing to inject.
    #
    # Takes anything carrying an `etsy_listing_id` — a BoardPrintable while the
    # scalar columns survive, or a BoardPrintableListing row.
    def etsy_listing_url_for(record)
      return nil if record.etsy_listing_id.blank?

      "https://www.etsy.com/your/shops/me/listing-editor/edit/#{record.etsy_listing_id.to_i}#media"
    end

    def etsy_listing_state_badge(listing)
      case listing.state
      when "published"  then "bg-green-900/60 text-green-300"
      when "publishing" then "bg-indigo-900/60 text-indigo-300"
      when "pending"    then "bg-amber-900/60 text-amber-300"
      when "failed"     then "bg-red-900/60 text-red-300"
      else "admin-card text-t2"
      end
    end

    # Deleting the record can't touch Etsy — Rails only ever creates drafts and
    # implements no update/delete call — so a printable already on Etsy has to
    # say so loudly, or an admin deletes the record and assumes the draft went
    # with it.
    def board_printable_delete_confirm(printable)
      base = "Delete this printable and its PDFs? This can't be undone."
      return base unless printable.etsy_ever_published?

      # The second sentence is the less obvious consequence: this record is what
      # freezes its boards, so deleting it makes them deletable and renameable
      # again while the listing is still up.
      #
      # A relisted printable has no listing id to name — the draft it was
      # detached from is still on Etsy, so the warning is if anything more
      # important there, just less specific.
      ids = printable.etsy_listings.filter_map(&:etsy_listing_id)
      draft = if ids.any?
        "Etsy #{"draft".pluralize(ids.size)} #{ids.join(", ")} #{ids.one? ? "stays" : "stay"} on Etsy — " \
        "remove #{ids.one? ? "it" : "them"} there yourself."
      else
        "Any Etsy draft made from this printable stays on Etsy — remove it there yourself."
      end

      "#{base} #{draft} " \
      "The #{pluralize(printable.protected_board_ids.size, "board")} it protects will no longer be protected."
    end

    def marketplace_protection_badge
      "bg-amber-900/60 text-amber-300"
    end

    # The confirm on "Regenerate from topic". Says the destructive part first —
    # the copy is meant to be hand-edited before publishing, so rebuilding it is
    # the one action here that can lose work. The second half is the reassurance
    # an admin needs on a printable that is already listed: this is local.
    def regenerate_copy_confirm(printable)
      base = "Rebuild the title, summary, description and tags from the topic? " \
             "Any hand edits to them are replaced. The price is kept."
      return base unless printable.etsy_published?

      "#{base} Nothing is sent to Etsy — listing #{printable.etsy_listing_id} keeps its current copy " \
      "until you push it with the printables CLI."
    end

    # The confirm on "Add a listing". Says what it does NOT do: a row is local
    # until you publish it, so this cannot make a draft by accident.
    def create_listing_confirm(printable)
      existing = printable.etsy_listings.count
      base = "Add another listing to this printable? Nothing is sent to Etsy — you edit its copy first, " \
             "then create the draft from its own card."
      return base if existing.zero?

      "#{base} This printable already has #{pluralize(existing, "listing")}."
    end

    # The confirm on "Create Etsy draft" / "Retry". Names the title going out,
    # because the row's copy may differ from the printable's.
    def publish_listing_confirm(listing)
      "Create a draft Etsy listing for \"#{listing.resolved_copy["title"]}\"? " \
      "It will NOT go live — you publish it in Etsy yourself."
    end

    # The confirm on "Send video". `video_pushed_at` makes a second POST at the
    # SAME row refusable, but that stamp is this app's only memory: Etsy allows
    # ONE video per listing and there is no call here that can read a listing
    # back to check, so a draft that got a clip any other way still looks empty.
    # Naming the listing id is what lets an admin go and look before continuing.
    def push_video_confirm(listing)
      "Send this video to Etsy listing #{listing.etsy_listing_id}? " \
      "Etsy allows ONE video per listing and this app can't read the listing to check — " \
      "only continue if that listing has no video yet. It can't be undone from here; " \
      "replacing a listing's video is a seller-UI job."
    end

    # The confirm on "Detach". Says the two things an admin could otherwise get
    # wrong: nothing here touches the draft on Etsy, and the boards stay frozen
    # (protection is keyed on having ever been published, not on being attached).
    def supersede_listing_confirm(listing)
      count = listing.board_printable.protected_board_ids.size

      "Detach this listing from Etsy draft #{listing.etsy_listing_id}? " \
      "That draft is NOT deleted — remove it on Etsy yourself, or you'll have two. " \
      "The #{pluralize(count, "board")} it protects #{count == 1 ? "stays" : "stay"} protected."
    end

    # The confirm on "Replace" — detach plus a fresh row carrying the same copy.
    # The one-click version of what "Detach & relist" used to be, except the old
    # row survives so the draft it points at is still findable.
    def replace_listing_confirm(listing)
      "Detach from Etsy draft #{listing.etsy_listing_id} and add a replacement listing with the same copy? " \
      "That draft is NOT deleted — remove it on Etsy yourself. Publishing the replacement creates a new " \
      "draft with the current images and video."
    end

    # The confirm on the release button. Names the listing id, because that's
    # the thing an admin should go look at before deciding the paper is dead.
    def waive_protection_confirm(printable)
      ids = printable.etsy_listings.filter_map(&:etsy_listing_id)
      listings = ids.any? ? "Etsy #{"listing".pluralize(ids.size)} #{ids.join(", ")}" : "The Etsy listing"

      "Release protection on #{pluralize(printable.protected_board_ids.size, "board")}? " \
      "#{listings} may still be live, and printed copies keep pointing at these boards. " \
      "They become deletable, renameable and unpublishable again."
    end

    # The list is capped at PUBLIC_BOARD_LIMIT, so which boards you see depends
    # on the sort — the summary line says which one picked them.
    def board_sort_label(sort)
      case sort
      when "subboards"  then "subboard count"
      when "created_at" then "created date"
      when "updated_at" then "updated date"
      else "name"
      end
    end
  end
end
