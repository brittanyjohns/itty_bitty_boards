# Admin Signup + Plan-Change Notification Emails Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the admin "new user" alert fire exactly once per genuinely new account with actionable context and links, and add a separate correctly-labelled alert for plan upgrades.

**Architecture:** Signup platform and method are captured into the `users.settings` jsonb at each account-creation point. A single idempotent `User#notify_admin_of_signup!` replaces three scattered `AdminMailer.new_user_email` calls inside the welcome-email methods, so upgrades and manual welcome resends stop producing false new-signup alerts. A new `AdminMailer#plan_change_email` hangs off `User#send_plan_welcome_email_once!`, the one choke point that all three upgrade paths (Stripe webhook, RevenueCat, billing API) already funnel through.

**Tech Stack:** Rails 8, ActionMailer + ActiveJob (`deliver_later`, `:test` adapter in specs), RSpec + FactoryBot, existing `IpGeolocation` service, existing `AppEnv.staging?` helper.

**Spec:** `docs/superpowers/specs/2026-07-24-admin-signup-email-improvements-design.md`

## Global Constraints

- Brand name is always **SpeakAnyWay** (one word, S/A/W capitalized) in every string.
- All mailer dispatch uses `deliver_later`, never `deliver_now`. There is a regression guard at `spec/lib/no_inline_mailer_delivery_spec.rb`.
- Admin notification failures must never break a request: `notify_admin_of_signup!` rescues and logs, matching the "external-service failures fail soft" invariant in `CLAUDE.md`.
- No new gems. No migrations. No deployment/server config changes.
- Admin recipient is `ENV["ADMIN_EMAIL"] || "brittany@speakanyway.com"`, matching the other `AdminMailer` methods.
- Staging is **not** suppressed — subjects get a `[STAGING]` prefix when `AppEnv.staging?` is true.
- `tokens` must not appear in the new-user email body. It is the legacy field; credits are the real balance.
- Run specs with `bundle exec rspec <path>`.

## File Structure

| File | Responsibility |
|---|---|
| `app/models/user.rb` | Add `record_signup_context!` and `notify_admin_of_signup!`; remove three `AdminMailer.new_user_email` calls; add `source:` kwarg and the `plan_change_email` dispatch to `send_plan_welcome_email_once!` |
| `app/mailers/admin_mailer.rb` | Rewrite `new_user_email`; add `plan_change_email`; add a private `admin_subject` staging-prefix helper and a private `signup_location` helper |
| `app/views/admin_mailer/new_user_email.html.erb` | Rewritten body: who / how / plan / location / links |
| `app/views/admin_mailer/plan_change_email.html.erb` | New body: identity, from→to, billing, links |
| `app/views/admin_mailer/new_feedback_email.erb` | Header copy fix |
| `app/controllers/api/v1/auths_controller.rb` | Call the two new `User` methods in `sign_up` and `email_signup` |
| `app/controllers/api/webhooks_controller.rb` | Pass `source: "stripe"` |
| `app/services/revenue_cat/webhook_processor.rb` | Pass `source: "revenuecat"` |
| `app/controllers/api/billing_controller.rb` | Pass `source: "billing_api"` |
| `spec/models/user_admin_notification_spec.rb` | New: both `User` methods, idempotency, regression that welcome paths no longer notify |
| `spec/mailers/admin_mailer_spec.rb` | Extend: `new_user_email` and `plan_change_email` rendering |
| `spec/requests/api/v1/signup_admin_notification_spec.rb` | New: both signup endpoints write context and enqueue exactly one alert |
| `spec/mailers/previews/admin_mailer_preview.rb` | New: local preview for both templates |
| `.claude-notes/ops.md`, `CHANGELOG.md` | Docs |

---

### Task 1: Capture signup context and centralize the admin notification

**Files:**
- Modify: `app/models/user.rb` (add two methods near `send_general_welcome_email` at :1010; edit :1016, :1056, :1338)
- Modify: `app/controllers/api/v1/auths_controller.rb:34-49` and `:105-121`
- Test: `spec/models/user_admin_notification_spec.rb` (create)

**Interfaces:**
- Produces: `User#record_signup_context!(platform: nil, method: nil)` → writes `settings["signup_platform"]` (String, defaults `"web"`) and `settings["signup_method"]` (String or nil), then `save`. Returns the result of `save`.
- Produces: `User#notify_admin_of_signup!` → enqueues `AdminMailer.new_user_email(self)` at most once per account, sets `settings["admin_new_user_notified"] = true`. Returns nil for admins and for already-notified users.

- [ ] **Step 1: Write the failing test**

Create `spec/models/user_admin_notification_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "User admin signup notification" do
  include ActiveJob::TestHelper

  let(:user) { FactoryBot.create(:user) }

  describe "#record_signup_context!" do
    it "stores the platform and method" do
      user.record_signup_context!(platform: "ios", method: "standard")
      expect(user.reload.settings["signup_platform"]).to eq("ios")
      expect(user.settings["signup_method"]).to eq("standard")
    end

    it "defaults a blank platform to web" do
      user.record_signup_context!(platform: "", method: "email_only")
      expect(user.reload.settings["signup_platform"]).to eq("web")
    end

    it "persists on its own without a later save" do
      user.record_signup_context!(platform: "android", method: "standard")
      expect(User.find(user.id).settings["signup_platform"]).to eq("android")
    end
  end

  describe "#notify_admin_of_signup!" do
    it "enqueues the admin new-user email" do
      expect {
        user.notify_admin_of_signup!
      }.to have_enqueued_mail(AdminMailer, :new_user_email).with(user)
    end

    it "flags the user so it cannot send twice" do
      user.notify_admin_of_signup!
      expect(user.reload.settings["admin_new_user_notified"]).to be(true)
      expect {
        user.notify_admin_of_signup!
      }.not_to have_enqueued_mail(AdminMailer, :new_user_email)
    end

    it "does not notify for an admin account" do
      admin = FactoryBot.create(:admin_user)
      expect {
        admin.notify_admin_of_signup!
      }.not_to have_enqueued_mail(AdminMailer, :new_user_email)
    end

    it "swallows and logs a mailer failure instead of raising" do
      allow(AdminMailer).to receive(:new_user_email).and_raise(StandardError, "smtp down")
      expect(Rails.logger).to receive(:error).with(/Admin new-user notification failed/)
      expect { user.notify_admin_of_signup! }.not_to raise_error
    end
  end

  describe "welcome-email paths no longer notify the admin" do
    it "does not notify from send_welcome_email" do
      expect {
        user.send_welcome_email("free")
      }.not_to have_enqueued_mail(AdminMailer, :new_user_email)
    end

    it "does not notify from send_welcome_receipt_email" do
      expect {
        user.send_welcome_receipt_email
      }.not_to have_enqueued_mail(AdminMailer, :new_user_email)
    end

    it "does not notify from send_general_welcome_email" do
      expect {
        user.send_general_welcome_email
      }.not_to have_enqueued_mail(AdminMailer, :new_user_email)
    end
  end
end
```

Note: all three welcome methods also call `update_mailchimp_subscription`.
`send_welcome_email` and `send_welcome_receipt_email` rescue internally;
`send_general_welcome_email` has a bare `begin`/`end` with no rescue. If that
example raises against Mailchimp, stub it in the `describe` block with
`allow_any_instance_of(User).to receive(:update_mailchimp_subscription)` — the
subject under test is the admin notification, not the CRM sync. Do not "fix"
the missing rescue here; that is out of scope.

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/models/user_admin_notification_spec.rb`
Expected: FAIL — `NoMethodError: undefined method 'record_signup_context!'`, and the three "no longer notify" examples fail because the mail *is* currently enqueued.

- [ ] **Step 3: Add the two methods to `User`**

In `app/models/user.rb`, immediately above `def send_general_welcome_email` (currently line 1010):

```ruby
  # Records how and where this account was created so the admin signup alert
  # can report it. Stored in `settings` rather than columns: nothing queries
  # it, so a jsonb key avoids a migration and a backfill decision. Accounts
  # created before this shipped have neither key and render as "unknown".
  def record_signup_context!(platform: nil, method: nil)
    self.settings ||= {}
    settings["signup_platform"] = platform.presence || "web"
    settings["signup_method"] = method
    save
  end

  # Single entry point for the admin "new signup" alert. Deliberately NOT
  # called from the welcome-email methods: `send_plan_welcome_email_once!`
  # routes through `send_welcome_email`, so an upgrade used to send a "new
  # user signed up" alert, as did the admin dashboard's resend button.
  # Idempotent per account and fails soft — an admin notification must never
  # break a signup request.
  def notify_admin_of_signup!
    return if admin?
    self.settings ||= {}
    return if settings["admin_new_user_notified"]
    AdminMailer.new_user_email(self).deliver_later
    settings["admin_new_user_notified"] = true
    save
    nil
  rescue => e
    Rails.logger.error("Admin new-user notification failed for user #{id}: #{e.message}")
    nil
  end
```

- [ ] **Step 4: Remove the three old call sites**

In `app/models/user.rb`, delete the line `AdminMailer.new_user_email(self).deliver_later` from each of:
- `send_general_welcome_email` (line 1016)
- `send_welcome_email` (line 1056)
- `send_welcome_receipt_email` (line 1338)

Leave the surrounding `update_mailchimp_subscription` calls and logging untouched.

- [ ] **Step 5: Run test to verify it passes**

Run: `bundle exec rspec spec/models/user_admin_notification_spec.rb`
Expected: PASS, 10 examples, 0 failures.

- [ ] **Step 6: Write the failing request test**

Create `spec/requests/api/v1/signup_admin_notification_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "Signup admin notification", type: :request do
  include ActiveJob::TestHelper

  before do
    allow(User).to receive(:create_stripe_customer).and_return("cus_test_123")
  end

  describe "POST /api/v1/users/sign_up" do
    let(:params) do
      {
        email: "newsignup@example.com",
        password: "password123",
        password_confirmation: "password123",
        name: "New Signup",
        platform: "ios",
      }
    end

    it "records the signup context" do
      post "/api/v1/users/sign_up", params: params
      user = User.find_by(email: "newsignup@example.com")
      expect(user.settings["signup_platform"]).to eq("ios")
      expect(user.settings["signup_method"]).to eq("standard")
    end

    it "enqueues exactly one admin new-user email" do
      expect {
        post "/api/v1/users/sign_up", params: params
      }.to have_enqueued_mail(AdminMailer, :new_user_email).once
    end

    it "defaults the platform to web when the client sends none" do
      post "/api/v1/users/sign_up", params: params.except(:platform)
      expect(User.find_by(email: "newsignup@example.com").settings["signup_platform"]).to eq("web")
    end
  end

  describe "POST /api/v1/users/email_signup" do
    it "records the email_only method and enqueues one admin email" do
      expect {
        post "/api/v1/users/email_signup", params: { email: "paidintent@example.com", platform: "web" }
      }.to have_enqueued_mail(AdminMailer, :new_user_email).once
      user = User.find_by(email: "paidintent@example.com")
      expect(user.settings["signup_method"]).to eq("email_only")
      expect(user.settings["signup_platform"]).to eq("web")
    end
  end
end
```

- [ ] **Step 7: Run it to confirm the route paths and the failure**

Run: `bundle exec rspec spec/requests/api/v1/signup_admin_notification_spec.rb`
Expected: FAIL — `settings["signup_platform"]` is nil.

If instead it fails with `ActionController::RoutingError`, resolve the real paths with `bin/rails routes | grep -E "sign_up|email_signup"` and correct the two `post` paths in the spec before continuing.

- [ ] **Step 8: Wire the controllers**

In `app/controllers/api/v1/auths_controller.rb`, in `sign_up`, immediately after the `user.ensure_minimum_communicator_slot!` line (currently :36) and before the `if user.role == "partner"` block:

```ruby
          user.record_signup_context!(platform: platform, method: "standard")
          user.notify_admin_of_signup!
```

In `email_signup`, immediately after its `user.ensure_minimum_communicator_slot!` line (currently :107):

```ruby
        user.record_signup_context!(platform: platform, method: "email_only")
        user.notify_admin_of_signup!
```

Order matters: `record_signup_context!` saves first so the settings the mailer reads are already persisted when the job runs.

- [ ] **Step 9: Wire `create_from_email`**

In `app/models/user.rb`, inside `self.create_from_email`, in the `else` branch that currently reads `user.send_welcome_email if user.should_send_welcome_email?` (line 449), insert directly above that line:

```ruby
        user.record_signup_context!(method: slug ? "myspeak" : "email_import")
        user.notify_admin_of_signup!
```

No platform is available on this path, so it takes the `"web"` default.

- [ ] **Step 10: Run both specs to verify they pass**

Run: `bundle exec rspec spec/models/user_admin_notification_spec.rb spec/requests/api/v1/signup_admin_notification_spec.rb`
Expected: PASS, 14 examples, 0 failures.

- [ ] **Step 11: Run the existing dispatch and inline-delivery guards for regressions**

Run: `bundle exec rspec spec/models/user_mailer_dispatch_spec.rb spec/lib/no_inline_mailer_delivery_spec.rb spec/mailers/admin_mailer_spec.rb`
Expected: PASS, 0 failures.

- [ ] **Step 12: Commit**

```bash
git add app/models/user.rb app/controllers/api/v1/auths_controller.rb spec/models/user_admin_notification_spec.rb spec/requests/api/v1/signup_admin_notification_spec.rb
git commit -m "fix(admin-email): fire the new-user alert once at signup, not from welcome paths"
```

---

### Task 2: Rewrite the new-user email with real context and links

**Files:**
- Modify: `app/mailers/admin_mailer.rb:12-18`
- Modify: `app/views/admin_mailer/new_user_email.html.erb` (full rewrite)
- Test: `spec/mailers/admin_mailer_spec.rb` (extend)

**Interfaces:**
- Consumes: `settings["signup_platform"]` / `settings["signup_method"]` from Task 1.
- Produces: `AdminMailer#new_user_email(user)` with subject `New signup: <email> (<Plan> · <platform>)`, prefixed `[STAGING] ` when `AppEnv.staging?`.
- Produces (private, reused by Task 3): `AdminMailer#admin_subject(text)` → String; `AdminMailer#admin_recipient` → String; `AdminMailer#signup_location(user)` → Hash or nil.

- [ ] **Step 1: Write the failing test**

Append inside the `RSpec.describe AdminMailer` block in `spec/mailers/admin_mailer_spec.rb`:

```ruby
  describe "#new_user_email" do
    let(:user) do
      FactoryBot.create(:user, name: "Jane Doe", email: "jane@example.com", plan_type: "free").tap do |u|
        u.update_columns(stripe_customer_id: "cus_ABC123", current_sign_in_ip: "8.8.8.8")
        u.record_signup_context!(platform: "ios", method: "standard")
      end
    end

    before { allow(IpGeolocation).to receive(:coarse).and_return(nil) }

    it "puts the email, plan, and platform in the subject" do
      mail = described_class.new_user_email(user).deliver_now
      expect(mail.to).to eq([ENV["ADMIN_EMAIL"] || "brittany@speakanyway.com"])
      expect(mail.subject).to eq("New signup: jane@example.com (free · ios)")
    end

    it "renders the signup context and omits the legacy tokens field" do
      body = described_class.new_user_email(user).deliver_now.html_part.body.decoded
      expect(body).to include("jane@example.com")
      expect(body).to include("standard")
      expect(body).to include("ios")
      expect(body).not_to match(/Tokens:/i)
    end

    it "links to the admin dashboard and the Stripe customer" do
      body = described_class.new_user_email(user).deliver_now.html_part.body.decoded
      expect(body).to include("/admin/users/#{user.id}")
      expect(body).to include("https://dashboard.stripe.com/customers/cus_ABC123")
    end

    it "omits the Stripe subscription link when there is no subscription" do
      body = described_class.new_user_email(user).deliver_now.html_part.body.decoded
      expect(body).not_to include("dashboard.stripe.com/subscriptions")
    end

    it "includes the Stripe subscription link when there is one" do
      user.update_columns(stripe_subscription_id: "sub_XYZ789")
      body = described_class.new_user_email(user).deliver_now.html_part.body.decoded
      expect(body).to include("https://dashboard.stripe.com/subscriptions/sub_XYZ789")
    end

    it "renders a coarse location when the lookup succeeds" do
      allow(IpGeolocation).to receive(:coarse).with("8.8.8.8")
        .and_return({ city: "Austin", region: "Texas", country: "US", label: "Austin, Texas, US" })
      body = described_class.new_user_email(user).deliver_now.html_part.body.decoded
      expect(body).to include("Austin, Texas, US")
    end

    it "omits the location row when the lookup returns nil" do
      body = described_class.new_user_email(user).deliver_now.html_part.body.decoded
      expect(body).not_to match(/Location/i)
    end

    it "renders unknown for an account with no captured signup context" do
      legacy = FactoryBot.create(:user, email: "legacy@example.com")
      body = described_class.new_user_email(legacy).deliver_now.html_part.body.decoded
      expect(body).to include("unknown")
    end

    it "prefixes the subject on staging" do
      allow(AppEnv).to receive(:staging?).and_return(true)
      expect(described_class.new_user_email(user).subject).to start_with("[STAGING] ")
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/mailers/admin_mailer_spec.rb -e "#new_user_email"`
Expected: FAIL — the subject is still `"New user signed up for SpeakAnyWay AAC!!"`.

- [ ] **Step 3: Rewrite the mailer method**

Replace lines 12–18 of `app/mailers/admin_mailer.rb` with:

```ruby
  def new_user_email(user)
    @user = user
    @signup_platform = user.settings&.dig("signup_platform") || "unknown"
    @signup_method = user.settings&.dig("signup_method") || "unknown"
    @location = signup_location(user)
    subject = admin_subject(
      "New signup: #{user.email} (#{user.plan_type} · #{@signup_platform})",
    )
    mail(to: admin_recipient, subject: subject, from: "noreply@speakanyway.com")
  end
```

Then add, at the bottom of the class before the final `end`:

```ruby
  private

  def admin_recipient
    ENV["ADMIN_EMAIL"] || "brittany@speakanyway.com"
  end

  # Staging runs with RAILS_ENV=production and the same ADMIN_EMAIL, so tag the
  # subject rather than suppressing the send — that keeps these alerts
  # verifiable end-to-end on staging without them reading as production signups.
  def admin_subject(text)
    AppEnv.staging? ? "[STAGING] #{text}" : text
  end

  # Coarse city-level location for the signup IP. Runs inside the deliver_later
  # job, never on the request path. IpGeolocation.coarse is total — it returns
  # nil for a private/unparseable IP or any provider error — and the template
  # drops the whole row when this is nil.
  def signup_location(user)
    ip = user.current_sign_in_ip.presence || user.last_sign_in_ip.presence
    return nil if ip.blank?
    IpGeolocation.coarse(ip)
  end
```

Note: `@admin` is no longer used by this template, so the `User.find_by(id: User::DEFAULT_ADMIN_ID)` lookup is dropped from `new_user_email`. Leave it in place in `new_feedback_email`, which still renders `@admin.name`.

- [ ] **Step 4: Rewrite the view**

Replace the entire contents of `app/views/admin_mailer/new_user_email.html.erb`:

```erb
<div class="container">
  <%= render "layouts/email_logo" %>
  <div class="header">
    <p>SpeakAnyWay has a new user! 🎉</p>
  </div>
  <div class="content">
    <table width="100%" cellpadding="6" cellspacing="0" style="border-collapse:collapse; font-size:14px;">
      <tr style="background:#f4f2ff; text-align:left;">
        <th colspan="2" style="padding:6px;">Who</th>
      </tr>
      <tr><td style="padding:6px;">Name</td><td style="padding:6px;"><%= @user.name.presence || "—" %></td></tr>
      <tr><td style="padding:6px;">Email</td><td style="padding:6px;"><%= @user.email %></td></tr>
      <tr><td style="padding:6px;">User ID</td><td style="padding:6px;"><%= @user.id %></td></tr>
      <tr><td style="padding:6px;">Role</td><td style="padding:6px;"><%= @user.role.presence || "—" %></td></tr>

      <tr style="background:#f4f2ff; text-align:left;">
        <th colspan="2" style="padding:6px;">How they signed up</th>
      </tr>
      <tr><td style="padding:6px;">Method</td><td style="padding:6px;"><%= @signup_method %></td></tr>
      <tr><td style="padding:6px;">Platform</td><td style="padding:6px;"><%= @signup_platform %></td></tr>
      <tr><td style="padding:6px;">Signed up</td><td style="padding:6px;"><%= @user.created_at&.strftime("%b %d, %Y at %l:%M %p %Z") %></td></tr>
      <% if @location %>
        <tr><td style="padding:6px;">Location</td><td style="padding:6px;"><%= @location[:label] %></td></tr>
      <% end %>

      <tr style="background:#f4f2ff; text-align:left;">
        <th colspan="2" style="padding:6px;">Plan</th>
      </tr>
      <tr><td style="padding:6px;">Plan type</td><td style="padding:6px;"><%= @user.plan_type %></td></tr>
      <tr><td style="padding:6px;">Plan status</td><td style="padding:6px;"><%= @user.plan_status %></td></tr>
    </table>

    <hr>
    <p>
      <a href="<%= admin_dashboard_user_url(@user) %>">Open in admin dashboard</a>
      <% if @user.stripe_customer_id.present? %>
        &middot; <a href="https://dashboard.stripe.com/customers/<%= @user.stripe_customer_id %>">Stripe customer</a>
      <% end %>
      <% if @user.stripe_subscription_id.present? %>
        &middot; <a href="https://dashboard.stripe.com/subscriptions/<%= @user.stripe_subscription_id %>">Stripe subscription</a>
      <% end %>
    </p>
  </div>
</div>
```

The word "Location" appears only inside the `if @location` guard, which is what the "omits the location row" test asserts.

- [ ] **Step 5: Run test to verify it passes**

Run: `bundle exec rspec spec/mailers/admin_mailer_spec.rb`
Expected: PASS, all examples including the pre-existing `disk_space_alert` and `partner_pilot_review` groups.

If `admin_dashboard_user_url` raises `ArgumentError: Missing host to link to`, confirm the helper name with `bin/rails routes -g admin | grep dashboard_user` and that `Rails.application.routes.default_url_options[:host]` is set in `config/environments/test.rb:7`.

- [ ] **Step 6: Commit**

```bash
git add app/mailers/admin_mailer.rb app/views/admin_mailer/new_user_email.html.erb spec/mailers/admin_mailer_spec.rb
git commit -m "feat(admin-email): rich new-signup alert with platform, location, and Stripe links"
```

---

### Task 3: Add the plan-change email

**Files:**
- Modify: `app/mailers/admin_mailer.rb` (add `plan_change_email` above the `private` section)
- Create: `app/views/admin_mailer/plan_change_email.html.erb`
- Modify: `app/models/user.rb:1350-1359` (`send_plan_welcome_email_once!`)
- Modify: `app/controllers/api/webhooks_controller.rb:516`
- Modify: `app/services/revenue_cat/webhook_processor.rb:144`
- Modify: `app/controllers/api/billing_controller.rb:48`
- Test: `spec/mailers/admin_mailer_spec.rb`, `spec/models/user_admin_notification_spec.rb`

**Interfaces:**
- Consumes: `AdminMailer#admin_subject`, `#admin_recipient` from Task 2.
- Produces: `AdminMailer#plan_change_email(user, from_plan:, to_plan:, source:)` — all keywords required, all Strings. Subject `Upgrade: <email> <from> → <to> (<Source>)`.
- Produces: `User#send_plan_welcome_email_once!(plan_nickname, source: "unknown")` — `source` is a new optional keyword; existing positional behavior is unchanged.

- [ ] **Step 1: Write the failing mailer test**

Append inside the `RSpec.describe AdminMailer` block in `spec/mailers/admin_mailer_spec.rb`:

```ruby
  describe "#plan_change_email" do
    let(:user) do
      FactoryBot.create(:user, name: "Jane Doe", email: "jane@example.com", plan_type: "pro").tap do |u|
        u.update_columns(stripe_customer_id: "cus_ABC123", stripe_subscription_id: "sub_XYZ789", monthly_price: 19.99)
        u.settings["billing_interval"] = "month"
        u.save
      end
    end

    it "names both plans and the source in the subject" do
      mail = described_class.plan_change_email(user, from_plan: "free", to_plan: "pro", source: "stripe").deliver_now
      expect(mail.to).to eq([ENV["ADMIN_EMAIL"] || "brittany@speakanyway.com"])
      expect(mail.subject).to eq("Upgrade: jane@example.com free → pro (stripe)")
    end

    it "renders the plan transition, billing interval, and Stripe links" do
      body = described_class.plan_change_email(user, from_plan: "free", to_plan: "pro", source: "stripe")
        .deliver_now.html_part.body.decoded
      expect(body).to include("free")
      expect(body).to include("pro")
      expect(body).to include("month")
      expect(body).to include("https://dashboard.stripe.com/subscriptions/sub_XYZ789")
      expect(body).to include("/admin/users/#{user.id}")
    end

    it "prefixes the subject on staging" do
      allow(AppEnv).to receive(:staging?).and_return(true)
      mail = described_class.plan_change_email(user, from_plan: "free", to_plan: "pro", source: "stripe")
      expect(mail.subject).to start_with("[STAGING] ")
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/mailers/admin_mailer_spec.rb -e "#plan_change_email"`
Expected: FAIL — `NoMethodError: undefined method 'plan_change_email'`.

- [ ] **Step 3: Add the mailer method**

In `app/mailers/admin_mailer.rb`, directly above the `private` keyword added in Task 2:

```ruby
  # Admin alert for a paid plan change, fired from
  # User#send_plan_welcome_email_once! — the one choke point the Stripe
  # webhook, RevenueCat, and the billing API all route through. That method's
  # per-plan idempotency and its trialing/active transition guard mean this
  # fires once per real upgrade and never on a renewal or a downgrade.
  def plan_change_email(user, from_plan:, to_plan:, source:)
    @user = user
    @from_plan = from_plan
    @to_plan = to_plan
    @source = source
    @billing_interval = user.settings&.dig("billing_interval")
    @trial_ends_at = user.settings&.dig("trial_ends_at")
    subject = admin_subject("Upgrade: #{user.email} #{from_plan} → #{to_plan} (#{source})")
    mail(to: admin_recipient, subject: subject, from: "noreply@speakanyway.com")
  end
```

- [ ] **Step 4: Create the view**

Create `app/views/admin_mailer/plan_change_email.html.erb`:

```erb
<div class="container">
  <%= render "layouts/email_logo" %>
  <div class="header">
    <p>A SpeakAnyWay user upgraded! 🎉</p>
  </div>
  <div class="content">
    <table width="100%" cellpadding="6" cellspacing="0" style="border-collapse:collapse; font-size:14px;">
      <tr style="background:#f4f2ff; text-align:left;">
        <th colspan="2" style="padding:6px;">Who</th>
      </tr>
      <tr><td style="padding:6px;">Name</td><td style="padding:6px;"><%= @user.name.presence || "—" %></td></tr>
      <tr><td style="padding:6px;">Email</td><td style="padding:6px;"><%= @user.email %></td></tr>
      <tr><td style="padding:6px;">User ID</td><td style="padding:6px;"><%= @user.id %></td></tr>

      <tr style="background:#f4f2ff; text-align:left;">
        <th colspan="2" style="padding:6px;">Plan change</th>
      </tr>
      <tr><td style="padding:6px;">From</td><td style="padding:6px;"><%= @from_plan %></td></tr>
      <tr><td style="padding:6px;">To</td><td style="padding:6px;"><%= @to_plan %></td></tr>
      <tr><td style="padding:6px;">Status</td><td style="padding:6px;"><%= @user.plan_status %></td></tr>
      <tr><td style="padding:6px;">Source</td><td style="padding:6px;"><%= @source %></td></tr>
      <% if @billing_interval.present? %>
        <tr><td style="padding:6px;">Billing interval</td><td style="padding:6px;"><%= @billing_interval %></td></tr>
      <% end %>
      <% if @trial_ends_at.present? %>
        <tr><td style="padding:6px;">Trial ends</td><td style="padding:6px;"><%= @trial_ends_at %></td></tr>
      <% end %>
      <tr><td style="padding:6px;">Monthly price</td><td style="padding:6px;"><%= number_to_currency(@user.monthly_price) %></td></tr>
      <tr><td style="padding:6px;">Yearly price</td><td style="padding:6px;"><%= number_to_currency(@user.yearly_price) %></td></tr>
    </table>

    <hr>
    <p>
      <a href="<%= admin_dashboard_user_url(@user) %>">Open in admin dashboard</a>
      <% if @user.stripe_customer_id.present? %>
        &middot; <a href="https://dashboard.stripe.com/customers/<%= @user.stripe_customer_id %>">Stripe customer</a>
      <% end %>
      <% if @user.stripe_subscription_id.present? %>
        &middot; <a href="https://dashboard.stripe.com/subscriptions/<%= @user.stripe_subscription_id %>">Stripe subscription</a>
      <% end %>
    </p>
  </div>
</div>
```

- [ ] **Step 5: Run the mailer test to verify it passes**

Run: `bundle exec rspec spec/mailers/admin_mailer_spec.rb`
Expected: PASS, 0 failures.

- [ ] **Step 6: Write the failing dispatch test**

Append inside `spec/models/user_admin_notification_spec.rb`, before its final `end`:

```ruby
  describe "#send_plan_welcome_email_once!" do
    let(:paid_user) { FactoryBot.create(:user, plan_type: "pro") }

    it "enqueues the plan change email for a paid plan" do
      expect {
        paid_user.send_plan_welcome_email_once!("pro", source: "stripe")
      }.to have_enqueued_mail(AdminMailer, :plan_change_email)
    end

    it "derives from_plan from the previously welcomed plan" do
      paid_user.settings["plan_welcome_sent_for"] = ["basic"]
      paid_user.save
      expect {
        paid_user.send_plan_welcome_email_once!("pro", source: "stripe")
      }.to have_enqueued_mail(AdminMailer, :plan_change_email)
        .with(paid_user, from_plan: "basic", to_plan: "pro", source: "stripe")
    end

    it "falls back to free when nothing was welcomed before" do
      expect {
        paid_user.send_plan_welcome_email_once!("pro", source: "revenuecat")
      }.to have_enqueued_mail(AdminMailer, :plan_change_email)
        .with(paid_user, from_plan: "free", to_plan: "pro", source: "revenuecat")
    end

    it "defaults source to unknown when the caller omits it" do
      expect {
        paid_user.send_plan_welcome_email_once!("pro")
      }.to have_enqueued_mail(AdminMailer, :plan_change_email)
        .with(paid_user, from_plan: "free", to_plan: "pro", source: "unknown")
    end

    it "does not enqueue a plan change email for a free plan" do
      expect {
        FactoryBot.create(:user).send_plan_welcome_email_once!("free")
      }.not_to have_enqueued_mail(AdminMailer, :plan_change_email)
    end

    it "does not re-enqueue for a plan already welcomed" do
      paid_user.send_plan_welcome_email_once!("pro", source: "stripe")
      expect {
        paid_user.send_plan_welcome_email_once!("pro", source: "stripe")
      }.not_to have_enqueued_mail(AdminMailer, :plan_change_email)
    end

    it "never enqueues the new-user alert" do
      expect {
        paid_user.send_plan_welcome_email_once!("pro", source: "stripe")
      }.not_to have_enqueued_mail(AdminMailer, :new_user_email)
    end
  end
```

- [ ] **Step 7: Run it to verify it fails**

Run: `bundle exec rspec spec/models/user_admin_notification_spec.rb -e "#send_plan_welcome_email_once!"`
Expected: FAIL — `ArgumentError: unknown keyword: :source`.

- [ ] **Step 8: Update `send_plan_welcome_email_once!`**

Replace the method body in `app/models/user.rb` (currently :1350-1359) with:

```ruby
  def send_plan_welcome_email_once!(plan_nickname, source: "unknown")
    return if admin?
    return if plan_nickname.blank?
    plan_key = plan_nickname.to_s
    sent_for = Array(settings["plan_welcome_sent_for"])
    return if sent_for.include?(plan_key)
    send_welcome_email(plan_key)
    # Admin alert for the upgrade. Guarded to paid tiers so the billing-API
    # path can't produce a "plan change" alert for a Free account. from_plan is
    # the last plan we welcomed — an account that upgraded before this shipped
    # has an empty list and reads "free". Accepted: this is an alert, not a
    # ledger (see the design doc's known limitation).
    unless plan_key.include?("free")
      AdminMailer.plan_change_email(
        self,
        from_plan: sent_for.last || "free",
        to_plan: plan_key,
        source: source,
      ).deliver_later
    end
    self.settings["plan_welcome_sent_for"] = (sent_for + [plan_key]).uniq
    save
  end
```

- [ ] **Step 9: Run it to verify it passes**

Run: `bundle exec rspec spec/models/user_admin_notification_spec.rb`
Expected: PASS, 0 failures.

- [ ] **Step 10: Pass `source` from the three callers**

`app/controllers/api/webhooks_controller.rb:516` — change:

```ruby
      user.send_plan_welcome_email_once!(user.plan_type, source: "stripe")
```

`app/services/revenue_cat/webhook_processor.rb:144` — change:

```ruby
      user.send_plan_welcome_email_once!(plan_type, source: "revenuecat")
```

`app/controllers/api/billing_controller.rb:48` — change:

```ruby
      current_user.send_plan_welcome_email_once!(current_user.plan_type, source: "billing_api")
```

- [ ] **Step 11: Run the webhook and billing specs for regressions**

Run: `bundle exec rspec spec/requests/api/webhooks_spec.rb spec/services/revenue_cat spec/requests/api/billing_controller_spec.rb 2>&1 | tail -20`
Expected: PASS, 0 failures.

If any of those spec paths do not exist, discover the real ones with `ls spec/requests/api | grep -iE "webhook|billing"` and `ls spec/services/revenue_cat`, and run those instead. Do not skip this step — these are the three call sites just changed.

- [ ] **Step 12: Commit**

```bash
git add app/mailers/admin_mailer.rb app/views/admin_mailer/plan_change_email.html.erb app/models/user.rb app/controllers/api/webhooks_controller.rb app/services/revenue_cat/webhook_processor.rb app/controllers/api/billing_controller.rb spec/mailers/admin_mailer_spec.rb spec/models/user_admin_notification_spec.rb
git commit -m "feat(admin-email): add plan-change alert for upgrades across Stripe, RevenueCat, and billing API"
```

---

### Task 4: Feedback email header fix, mailer preview, and docs

**Files:**
- Modify: `app/views/admin_mailer/new_feedback_email.erb:5`
- Create: `spec/mailers/previews/admin_mailer_preview.rb`
- Modify: `.claude-notes/ops.md`, `CHANGELOG.md`

**Interfaces:**
- Consumes: `AdminMailer#new_user_email` and `#plan_change_email` from Tasks 2 and 3.

- [ ] **Step 1: Fix the feedback email header**

In `app/views/admin_mailer/new_feedback_email.erb`, line 5 currently reads:

```erb
        <p>SpeakAnyWay has a new user! 🎉</p>
```

Replace with:

```erb
        <p>SpeakAnyWay has new feedback! 📝</p>
```

- [ ] **Step 2: Create the mailer preview**

Create `spec/mailers/previews/admin_mailer_preview.rb`:

```ruby
# Preview all emails at http://localhost:4000/rails/mailers/admin_mailer
class AdminMailerPreview < ActionMailer::Preview
  def new_user_email
    AdminMailer.new_user_email(preview_user)
  end

  def plan_change_email
    AdminMailer.plan_change_email(preview_user, from_plan: "free", to_plan: "pro", source: "stripe")
  end

  private

  def preview_user
    User.non_admin.order(created_at: :desc).first || User.first
  end
end
```

- [ ] **Step 3: Verify both previews render**

Run: `bin/dev` in one shell, then in another:

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:4000/rails/mailers/admin_mailer/new_user_email
```

Expected: `200`. Repeat for `/plan_change_email`. Stop `bin/dev` afterwards.

If the local database has no users, this returns a 500 — seed one with `bin/rails runner 'User.create!(email: "preview@example.com", password: "password123", role: "user")'` and retry.

- [ ] **Step 4: Document in `.claude-notes/ops.md`**

Append a new section at the end of `.claude-notes/ops.md`:

```markdown
## Admin notification emails

All go to `ENV["ADMIN_EMAIL"]` (fallback `brittany@speakanyway.com`) from
`AdminMailer`. Staging is **not** suppressed — subjects are prefixed
`[STAGING]` via the private `admin_subject` helper, so these stay verifiable
end-to-end before production. `disk_space_alert` is the exception: its job
skips staging entirely.

- **`new_user_email`** — fired only by `User#notify_admin_of_signup!`, which is
  called from `AuthsController#sign_up`, `#email_signup`, and
  `User.create_from_email`. **Never** call it from a welcome-email method:
  `send_plan_welcome_email_once!` routes through `send_welcome_email`, so
  doing that makes every upgrade — and every admin-dashboard "Send welcome
  email" click — send a "new user signed up" alert. That was the bug.
  Idempotent on `settings["admin_new_user_notified"]`; rescues and logs.
  Reports `settings["signup_platform"]` / `["signup_method"]`, written by
  `User#record_signup_context!` at each creation point (accounts predating it
  render "unknown"), plus a coarse `IpGeolocation` location and deep links to
  the admin dashboard and Stripe.
- **`plan_change_email`** — fired from `User#send_plan_welcome_email_once!`,
  the single choke point for the Stripe webhook, RevenueCat, and the billing
  API; each passes a `source:`. Inherits that method's per-plan idempotency
  and its trialing/active transition guard, so renewals and downgrades never
  fire it. Skipped for free tiers. `from_plan` is the last entry in
  `settings["plan_welcome_sent_for"]`, falling back to `"free"` — approximate
  for accounts that upgraded before it shipped, which is acceptable for an
  alert.
- **`partner_pilot_review`** — `PartnerPilotEndingJob` digest.
- **`disk_space_alert`** — `DiskSpaceAlertJob`; see above.
```

- [ ] **Step 5: Add the CHANGELOG entry**

In `CHANGELOG.md`, directly under the `## [Unreleased]` heading, insert:

```markdown
### Fixed — Admin signup alerts no longer fire on upgrades
- The "new user signed up" admin email was sent from inside three welcome-email
  methods. Because `send_plan_welcome_email_once!` routes through
  `send_welcome_email`, every Stripe trial→active transition, RevenueCat
  purchase, plan upgrade, and admin-dashboard "Send welcome email" click sent
  an alert claiming a brand-new signup. It now fires from a single idempotent
  `User#notify_admin_of_signup!` at the three real account-creation points.
- The alert also carries real context now: the signup method and platform
  (captured at signup instead of being discarded), a coarse location from the
  signup IP, and deep links to the admin dashboard, the Stripe customer, and
  the Stripe subscription. The legacy `tokens` field was dropped from the body.

### Added — Admin plan-change email
- Upgrades send their own `AdminMailer#plan_change_email`, naming both plans and
  the source (Stripe, RevenueCat, or the billing API). Fired from
  `send_plan_welcome_email_once!`, so it inherits that method's per-plan
  idempotency: renewals and downgrades do not trigger it.

### Fixed — Feedback email header
- The admin feedback email rendered "SpeakAnyWay has a new user! 🎉" in its
  header, copy-pasted from the signup email.
```

- [ ] **Step 6: Run the full mailer and notification suite**

Run: `bundle exec rspec spec/mailers spec/models/user_admin_notification_spec.rb spec/requests/api/v1/signup_admin_notification_spec.rb spec/models/user_mailer_dispatch_spec.rb spec/lib/no_inline_mailer_delivery_spec.rb`
Expected: PASS, 0 failures.

- [ ] **Step 7: Commit**

```bash
git add app/views/admin_mailer/new_feedback_email.erb spec/mailers/previews/admin_mailer_preview.rb CHANGELOG.md
git add -f .claude-notes/ops.md
git commit -m "docs(admin-email): document admin alert surface, add mailer preview, fix feedback header"
```

Note the `git add -f` — `.claude-notes/` is gitignored and durable spoke docs are force-added, per `CLAUDE.md`.
