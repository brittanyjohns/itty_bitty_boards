class CreateBetaRequests < ActiveRecord::Migration[7.1]
  def change
    create_table :beta_requests do |t|
      t.string :email

      t.timestamps
    end
  end
end
