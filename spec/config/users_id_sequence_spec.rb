require "rails_helper"

# Guards the invariant that keeps pinned-id admin specs from poisoning whatever
# runs after them in the same process. See spec/support/users_id_sequence.rb.
RSpec.describe UsersIdSequence do
  let(:connection) { ActiveRecord::Base.connection }

  def sequence_value
    connection.select_value(
      "SELECT COALESCE(pg_sequence_last_value(pg_get_serial_sequence('users', 'id')::regclass), 0)"
    ).to_i
  end

  def desync_sequence!(to)
    connection.execute("SELECT setval(pg_get_serial_sequence('users', 'id'), #{to}, false)")
  end

  it "starts every example with the next id clear of DEFAULT_ADMIN_ID and of MAX(id)" do
    expect(described_class.next_id).to be > User::DEFAULT_ADMIN_ID
    expect(described_class.next_id).to be > (User.maximum(:id) || 0)
  end

  it "lets a spec pin the admin at DEFAULT_ADMIN_ID and still build users afterwards" do
    admin = User.find_by(id: User::DEFAULT_ADMIN_ID) ||
            FactoryBot.create(:admin_user, id: User::DEFAULT_ADMIN_ID)

    expect(admin.id).to eq(User::DEFAULT_ADMIN_ID)
    expect { FactoryBot.create(:user) }.not_to raise_error
    expect(FactoryBot.create(:user).id).to be > User::DEFAULT_ADMIN_ID
  end

  describe ".ensure_clear!" do
    it "repairs a sequence that would hand out an already-pinned id" do
      FactoryBot.create(:admin_user, id: User::DEFAULT_ADMIN_ID)
      # What a fresh database looks like after an explicit-id insert: the
      # sequence never advanced, so nextval would return DEFAULT_ADMIN_ID.
      desync_sequence!(User::DEFAULT_ADMIN_ID)
      expect(described_class.next_id).to eq(User::DEFAULT_ADMIN_ID)

      described_class.ensure_clear!

      expect(FactoryBot.create(:user).id).to be > User::DEFAULT_ADMIN_ID
    end

    it "leaves headroom above MAX(id) rather than sitting on it" do
      FactoryBot.create(:admin_user, id: User::DEFAULT_ADMIN_ID)
      described_class.ensure_clear!

      expect(described_class.next_id).to be > described_class::FLOOR
    end

    it "never moves the sequence backwards" do
      described_class.ensure_clear!
      high = sequence_value + 5_000
      connection.execute("SELECT setval(pg_get_serial_sequence('users', 'id'), #{high}, true)")

      described_class.ensure_clear!

      expect(sequence_value).to eq(high)
    end

    it "is idempotent" do
      described_class.ensure_clear!
      before = sequence_value
      described_class.ensure_clear!

      expect(sequence_value).to eq(before)
    end
  end
end
