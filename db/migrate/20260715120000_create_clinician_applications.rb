class CreateClinicianApplications < ActiveRecord::Migration[8.0]
  def change
    create_table :clinician_applications do |t|
      t.references :user, null: false, foreign_key: true
      t.string :full_name
      t.string :credential_type
      t.string :license_id
      t.string :workplace
      t.string :status, null: false, default: "pending"
      t.bigint :reviewed_by_id
      t.datetime :reviewed_at
      t.text :notes

      t.timestamps
    end

    add_index :clinician_applications, :status
    add_index :clinician_applications, :reviewed_by_id
    # One pending application per user (enforced in the model too). A partial
    # unique index lets a user re-apply after a denial without tripping the
    # constraint on the historical row.
    add_index :clinician_applications, :user_id,
              unique: true,
              where: "status = 'pending'",
              name: "index_clinician_applications_on_user_id_pending"
  end
end
