class AddSlugToGroups < ActiveRecord::Migration[7.1]
  def up
    add_column :board_groups, :slug, :string unless column_exists?(:board_groups, :slug)
    add_index :board_groups, :slug, unique: true unless index_exists?(:board_groups, :slug)
    add_column :board_group_boards, :position, :integer, default: 0, null: false unless column_exists?(:board_group_boards, :position)
    add_column :board_group_boards, :group_layout, :jsonb, default: {}, null: false unless column_exists?(:board_group_boards, :group_layout)

    BoardGroup.reset_column_information
    BoardGroup.find_each do |group|
      next if group.slug.present?

      slug = group.name.parameterize
      existing_group = BoardGroup.find_by(slug: slug)
      if existing_group
        Rails.logger.warn "BoardGroup with slug '#{slug}' already exists. Generating a new slug."
        slug = "#{slug}-#{SecureRandom.hex(4)}"
      end
      group.update(slug: slug)
    end
  end

  def down
    remove_index :board_groups, :slug if index_exists?(:board_groups, :slug)
    remove_column :board_groups, :slug if column_exists?(:board_groups, :slug)
    remove_column :board_group_boards, :position if column_exists?(:board_group_boards, :position)
    remove_column :board_group_boards, :group_layout if column_exists?(:board_group_boards, :group_layout)
  end
end
