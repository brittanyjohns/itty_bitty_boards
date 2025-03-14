class AddPublishedToCommunicationBoards < ActiveRecord::Migration[7.1]
  def up
    add_column :child_boards, :published, :boolean, default: false unless column_exists?(:child_boards, :published)
    add_column :child_boards, :favorite, :boolean, default: false unless column_exists?(:child_boards, :favorite)
    add_index :child_boards, :published unless index_exists?(:child_boards, :published)
    add_index :child_boards, :favorite unless index_exists?(:child_boards, :favorite)
    add_column :boards, :published, :boolean, default: false unless column_exists?(:boards, :published)
    add_index :boards, :published unless index_exists?(:boards, :published)
    add_column :boards, :favorite, :boolean, default: false unless column_exists?(:boards, :favorite)
    add_index :boards, :favorite unless index_exists?(:boards, :favorite)
  end

  def down
    remove_column :child_boards, :favorite if column_exists?(:child_boards, :favorite)
    remove_column :child_boards, :published if column_exists?(:child_boards, :published)
    remove_index :child_boards, :favorite if index_exists?(:child_boards, :favorite)
    remove_index :child_boards, :published if index_exists?(:child_boards, :published)
    remove_column :boards, :favorite if column_exists?(:boards, :favorite)
    remove_column :boards, :published if column_exists?(:boards, :published)
    remove_index :boards, :favorite if index_exists?(:boards, :favorite)
    remove_index :boards, :published if index_exists?(:boards, :published)
  end
end
