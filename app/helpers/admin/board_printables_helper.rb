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
    def etsy_listing_url_for(printable)
      return nil if printable.etsy_listing_id.blank?

      "https://www.etsy.com/your/shops/me/listing-editor/edit/#{printable.etsy_listing_id.to_i}#media"
    end

    # Deleting the record can't touch Etsy — Rails only ever creates drafts and
    # implements no update/delete call — so a printable already on Etsy has to
    # say so loudly, or an admin deletes the record and assumes the draft went
    # with it.
    def board_printable_delete_confirm(printable)
      base = "Delete this printable and its PDFs? This can't be undone."
      return base unless printable.etsy_published?

      # The second sentence is the less obvious consequence: this record is what
      # freezes its boards, so deleting it makes them deletable and renameable
      # again while the listing is still up.
      "#{base} Etsy draft #{printable.etsy_listing_id} stays on Etsy — remove it there yourself. " \
      "The #{pluralize(printable.protected_board_ids.size, "board")} it protects will no longer be protected."
    end

    def marketplace_protection_badge
      "bg-amber-900/60 text-amber-300"
    end

    # The confirm on the release button. Names the listing id, because that's
    # the thing an admin should go look at before deciding the paper is dead.
    def waive_protection_confirm(printable)
      "Release protection on #{pluralize(printable.protected_board_ids.size, "board")}? " \
      "Etsy listing #{printable.etsy_listing_id} may still be live, and printed copies keep pointing at these boards. " \
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
