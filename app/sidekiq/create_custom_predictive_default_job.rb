class CreateCustomPredictiveDefaultJob
  include Sidekiq::Job

  def perform(user_id)
    user = User.find(user_id)
    return unless user
    board = Board.create_dynamic_default_for_user(user)

    if board
      Rails.logger.info "Created dynamic default board for user #{user.id}"
    else
      Rails.logger.error "Failed to create dynamic default board for user #{user.id}"
    end
  end
end
