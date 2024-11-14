class CreateCustomPredictiveDefaultJob
  include Sidekiq::Job

  def perform(user_id)
    user = User.find(user_id)
    board = Board.create_custom_predictive_default_for_user(user)
    puts "Created custom predictive default board for user #{user.id}"
    if board && board.images.none?
      original_board = Board.with_artifacts.find_by(name: "Predictive Default", user_id: User::DEFAULT_ADMIN_ID, parent_type: "PredefinedResource")

      if original_board
        if original_board.id == board.id
          puts "Original board is the same as Predictive Default"
        else
          original_board.images.each do |image|
            board.add_image(image.id)
          end
          puts "Added images to Predictive Default"
        end
      end
      FormatBoardWithAiJob.perform_async(board.id, "lg")
    end

    # Do something
  end
end
