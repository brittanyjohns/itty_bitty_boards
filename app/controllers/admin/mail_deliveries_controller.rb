module Admin
  # The product-side answer to "did that email actually send?" — the question
  # #820 and #824 both had to answer over SSH. Read-only; the rows are written
  # by MailDeliveryObserver and ApplicationMailer's rescue_from.
  class MailDeliveriesController < Admin::ApplicationController
    PER_PAGE = 100

    def index
      scope = MailDelivery.recent_first
      scope = scope.where(status: @status) if (@status = params[:status].presence_in(MailDelivery::STATUSES))

      # Recipient search is the shape of the real question ("what did
      # bhannajohns+dana@gmail.com get?"), so it matches anywhere in the
      # recipient list rather than requiring the exact envelope string.
      if (@query = params[:q].to_s.strip).present?
        scope = scope.where("recipients ILIKE :q OR subject ILIKE :q OR message_id ILIKE :q", q: "%#{@query}%")
      end

      @deliveries = scope.limit(PER_PAGE)
      @counts = MailDelivery.where(created_at: 7.days.ago..).group(:status).count
      @retention_days = MailDelivery.retention_days
    end
  end
end
