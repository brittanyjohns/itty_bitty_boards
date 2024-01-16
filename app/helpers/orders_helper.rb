module OrdersHelper
  STATUS_COLORS = { in_progress: "warning",
                    placed: "success",
                    shipped: "success",
                    cancelled: "danger",
                    failed: "danger",
                    locked: "danger" }

  def order_status_badge(order)
    "<span class='badge bg-#{STATUS_COLORS[order.status.to_sym]} small float-end'>#{order.status.titleize} </span>".html_safe
  end
end
