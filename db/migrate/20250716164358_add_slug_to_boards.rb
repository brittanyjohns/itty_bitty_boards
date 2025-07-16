class AddSlugToBoards < ActiveRecord::Migration[7.1]
  def up
    add_column :boards, :slug, :string, default: "" if !column_exists?(:boards, :slug)
    add_index :boards, :slug if !index_exists?(:boards, :slug)
    Board.reset_column_information

    Board.find_each do |board|
      slug = board.name.parameterize
      existing_board = Board.find_by(slug: slug)
      if existing_board && existing_board.id != board.id
        Rails.logger.warn "Board #{board.id} has a duplicate slug '#{slug}', generating a new one."
        slug = "#{slug}-#{board.id}"
      end
      board.slug = slug if board.slug.blank? || board.slug != slug
      saved = board.update(slug: slug)
      if saved
        Rails.logger.info "Board #{board.id} slug set to '#{board.slug}'"
      else
        Rails.logger.error "Failed to set slug for board #{board.id}: #{board.errors.full_messages.join(", ")}"
      end
    end
  end

  def down
    remove_index :boards, :slug if index_exists?(:boards, :slug)
    remove_column :boards, :slug if column_exists?(:boards, :slug)
  end
end
