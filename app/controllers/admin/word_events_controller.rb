module Admin
  class WordEventsController < Admin::ApplicationController
    SORTABLE = %w[created_at word user_id].freeze

    def index
      @sort = params[:sort].presence_in(SORTABLE) || "created_at"
      @dir = params[:dir].presence_in(%w[asc desc]) || "desc"

      scope = WordEvent.includes(:user, :child_account, :board, :image).where.not(user_id: current_user.id)
      @word_events = scope.order(@sort => @dir.to_sym).limit(100)
    end
  end
end
