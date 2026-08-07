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
