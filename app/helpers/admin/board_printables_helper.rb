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
  end
end
