# frozen_string_literal: true

require "rails_helper"

# Issue #928 — the owner could not tell whether an invite email ever arrived.
#
# `member_views` reported `invited / joined` and nothing about the MESSAGE, so
# one roster row ("Invited — hasn't joined yet") covered three different
# situations: delivered and ignored, FAILED to a bad address, and SUPPRESSED by
# the staging interceptor. `MailDelivery` recorded all three already; nothing
# published them.
#
# `mail_deliveries` carries no foreign key to a team, an invite or a user — it
# stores envelope data only, on purpose — so the correlation is envelope-shaped:
# the newest row whose `recipients` is the member's address, scoped to the
# invitation mailer by `mailer` OR `subject` (the observer writes a subject and
# no mailer; ApplicationMailer's rescue_from writes both).
RSpec.describe Team, "#member_views last_invite_delivery", type: :model do
  let(:owner) { create(:user, created_at: 2.months.ago) }
  let(:account) { create(:child_account, user: owner, owner: owner) }
  let(:team) { account.ensure_team!(creator: owner) }
  let(:invitee) { create(:user, created_at: 2.months.ago) }

  let(:invite_subject) { I18n.t("base_mailer.team_invitation_email.subject", locale: :en) }

  def record_invite_mail(status:, to:, reason: nil, error_class: nil, error_message: nil, at: Time.current)
    MailDelivery.create!(
      status: status,
      recipients: to,
      from_address: "noreply@speakanyway.com",
      # A DELIVERED/SUPPRESSED row is written by the observer, which sees only a
      # Mail::Message: subject, no mailer. A FAILED row comes from
      # ApplicationMailer's rescue_from, which knows the action.
      subject: invite_subject,
      mailer: (status == MailDelivery::FAILED ? MailDelivery::INVITE_MAILER_ACTION : nil),
      reason: reason,
      error_class: error_class,
      error_message: error_message,
      created_at: at,
      updated_at: at,
    )
  end

  def row_for(user)
    team.reload.member_views(team.account_owner_ids).find { |m| m[:user_id] == user.id }
  end

  before { team.upsert_member!(invitee, "supervisor", accepted: false) }

  it "reports a delivered invite with its timestamp and no reason" do
    sent_at = 2.days.ago.change(usec: 0)
    record_invite_mail(status: MailDelivery::DELIVERED, to: invitee.email, at: sent_at)

    delivery = row_for(invitee)[:last_invite_delivery]

    expect(delivery[:status]).to eq("delivered")
    expect(delivery[:reason]).to be_nil
    expect(delivery[:at]).to eq(sent_at.utc.iso8601)
  end

  it "reports a failed invite and names the transport's own error" do
    record_invite_mail(
      status: MailDelivery::FAILED,
      to: invitee.email,
      error_class: "Net::SMTPFatalError",
      error_message: "550 5.1.1 The email account that you tried to reach does not exist",
    )

    delivery = row_for(invitee)[:last_invite_delivery]

    expect(delivery[:status]).to eq("failed")
    expect(delivery[:reason]).to include("550 5.1.1")
  end

  it "reports a suppressed invite and says why it was dropped" do
    record_invite_mail(status: MailDelivery::SUPPRESSED, to: invitee.email, reason: "staging")

    delivery = row_for(invitee)[:last_invite_delivery]

    expect(delivery[:status]).to eq("suppressed")
    expect(delivery[:reason]).to eq("staging")
  end

  # The whole point of the nil: "no information on record" must never be read
  # as success. A row is pruned on a retention window, so an old invite
  # legitimately has none.
  it "reports nil when nothing is on record, distinguishably from delivered" do
    delivered = create(:user, created_at: 2.months.ago)
    team.upsert_member!(delivered, "member", accepted: false)
    record_invite_mail(status: MailDelivery::DELIVERED, to: delivered.email)

    expect(row_for(invitee)).to have_key(:last_invite_delivery)
    expect(row_for(invitee)[:last_invite_delivery]).to be_nil
    expect(row_for(delivered)[:last_invite_delivery][:status]).to eq("delivered")
  end

  it "reports nil once the record has been pruned" do
    record_invite_mail(status: MailDelivery::DELIVERED, to: invitee.email,
                       at: (MailDelivery.retention_days + 1).days.ago)
    MailDelivery.prune!

    expect(row_for(invitee)[:last_invite_delivery]).to be_nil
  end

  it "reports the MOST RECENT outcome when an invite was re-sent" do
    record_invite_mail(status: MailDelivery::FAILED, to: invitee.email, at: 5.days.ago,
                       error_class: "Net::SMTPFatalError", error_message: "550 rejected")
    record_invite_mail(status: MailDelivery::DELIVERED, to: invitee.email, at: 1.hour.ago)

    expect(row_for(invitee)[:last_invite_delivery][:status]).to eq("delivered")
  end

  it "ignores mail to the same address that is not a team invitation" do
    MailDelivery.create!(status: MailDelivery::DELIVERED, recipients: invitee.email,
                         subject: "Welcome to SpeakAnyWay", mailer: "UserMailer#welcome_email")

    expect(row_for(invitee)[:last_invite_delivery]).to be_nil
  end

  it "never attributes one member's outcome to another" do
    other = create(:user, created_at: 2.months.ago)
    team.upsert_member!(other, "member", accepted: false)
    record_invite_mail(status: MailDelivery::FAILED, to: other.email,
                       error_class: "Net::SMTPFatalError", error_message: "550 rejected")

    expect(row_for(invitee)[:last_invite_delivery]).to be_nil
    expect(row_for(other)[:last_invite_delivery][:status]).to eq("failed")
  end

  # The correlation has to hold for rows the app actually writes, not only for
  # hand-built ones — nothing in `MailDelivery.record` is told which mailer the
  # observer is watching.
  it "matches the row a real invite send leaves behind" do
    expect { BaseMailer.team_invitation_email(invitee, owner, team, "supervisor").deliver_now }
      .to change(MailDelivery, :count).by(1)

    delivery = row_for(invitee)[:last_invite_delivery]

    expect(delivery).to be_present
    expect(delivery[:status]).to eq(MailDelivery.last.status)
  end

  it "serializes to the fixed JSON shape the frontend reads" do
    record_invite_mail(status: MailDelivery::SUPPRESSED, to: invitee.email, reason: "staging")

    json = JSON.parse(team.reload.show_api_view(owner).to_json)
    row = json["members"].find { |m| m["user_id"] == invitee.id }

    expect(row["last_invite_delivery"].keys).to contain_exactly("status", "reason", "at")
    expect(row["last_invite_delivery"]["status"]).to eq("suppressed")
    expect(row["last_invite_delivery"]["reason"]).to eq("staging")
    expect(Time.iso8601(row["last_invite_delivery"]["at"])).to be_within(5.seconds).of(Time.current)
  end

  describe "batching" do
    # Counts real SQL, ignoring transaction bookkeeping — same shape as
    # spec/models/child_account_api_view_performance_spec.rb.
    def count_queries
      queries = 0
      callback = lambda do |_name, _start, _finish, _id, payload|
        next if payload[:sql].to_s.match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)

        queries += 1
      end
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
      queries
    end

    def add_invited_members(target, count)
      count.times do
        member = create(:user, created_at: 2.months.ago)
        target.upsert_member!(member, "member", accepted: false)
        record_invite_mail(status: MailDelivery::DELIVERED, to: member.email)
      end
    end

    it "does not grow the roster query count with the number of members" do
      small = account.ensure_team!(creator: owner)
      add_invited_members(small, 2)

      big_owner = create(:user, created_at: 2.months.ago)
      big_account = create(:child_account, user: big_owner, owner: big_owner)
      big = big_account.ensure_team!(creator: big_owner)
      add_invited_members(big, 14)

      # Warm anything memoized at the class level (locale load, schema) so the
      # first call isn't charged for what the second gets for free.
      Team.find(small.id).member_views([])
      Team.find(big.id).member_views([])

      small_count = count_queries { Team.find(small.id).member_views([]) }
      big_count = count_queries { Team.find(big.id).member_views([]) }

      # 7x the members, and the delivery lookup is one query either way.
      expect(big_count).to eq(small_count)
      expect(big_count).to be <= 4
    end
  end
end
