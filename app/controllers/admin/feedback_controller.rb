module Admin
  class FeedbackController < Admin::ApplicationController
    def index
      @type = params[:type].presence_in(FeedbackItem::FEEDBACK_TYPES) || "all"
      @search = params[:search]

      scope = FeedbackItem.includes(:user)
      scope = scope.where(feedback_type: @type) unless @type == "all"
      if @search.present?
        term = "%#{@search}%"
        scope = scope.left_joins(:user).where(
          "feedback_items.subject ILIKE :t OR feedback_items.message ILIKE :t OR feedback_items.role ILIKE :t " \
          "OR feedback_items.device ILIKE :t OR feedback_items.platform ILIKE :t " \
          "OR users.email ILIKE :t OR users.name ILIKE :t",
          t: term,
        )
      end

      @feedback_items = scope.order(created_at: :desc).limit(200)
      @counts = FeedbackItem.group(:feedback_type).count
    end
  end
end
