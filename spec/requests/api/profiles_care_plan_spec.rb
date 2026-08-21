# frozen_string_literal: true

require "rails_helper"

# POST /api/profiles/:id/care_plan — the owner-only download for the care plan
# documents. Grover is stubbed throughout; there is no Chrome in CI.
RSpec.describe "API::Profiles care plan", type: :request do
  let(:parent) { create(:user, created_at: 2.months.ago, stripe_customer_id: "cus_parent_stub") }
  let(:slp) { create(:user, plan_type: "pro", created_at: 2.months.ago, stripe_customer_id: "cus_slp_stub") }
  let(:admin) { create(:user, role: "admin", created_at: 2.months.ago) }

  let!(:account) do
    create(:child_account, user: parent, owner: parent, status: ChildAccount::ACTIVE, passcode: "ownerpw1")
  end
  let!(:team) do
    t = account.ensure_team!(creator: slp)
    t.upsert_member!(parent, "admin")
    t.upsert_member!(slp, "supervisor")
    t
  end
  let!(:profile) do
    Profile.create!(profileable: account,
                    username: "cp-#{SecureRandom.hex(2)}",
                    slug: "cp-#{SecureRandom.hex(2)}")
  end

  let(:care) do
    { "care" => { "sections" => { "meals" => { "values" => { "textures" => ["soft"] } } } } }
  end
  let(:emergency) { { "allergies" => "peanuts" } }

  before do
    # Two calls per generate: the document, and the PNG thumbnail rendered
    # from the same HTML.
    allow(Grover).to receive(:new)
      .and_return(instance_double(Grover, to_pdf: "%PDF-stub", to_png: "\x89PNG-stub"))
    allow_any_instance_of(Profile).to receive(:generate_attachments!).and_return(true)
    allow_any_instance_of(Profile).to receive(:enqueue_audio_job_if_needed).and_return(true)
    allow_any_instance_of(Profile).to receive(:url_for_attachment)
      .and_return("https://cdn.example.test/care-plan.pdf")
  end

  def post_care_plan(user, params = {})
    post "/api/profiles/#{profile.id}/care_plan", params: params, headers: auth_headers(user)
  end

  context "with care and emergency info" do
    before { profile.update!(settings: care.merge(emergency)) }

    it "returns a URL to the combined plan for the owner" do
      post_care_plan(parent)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["url"]).to be_present
      expect(profile.reload.care_emergency_plan_pdf).to be_attached
    end

    it "defaults to the combined variant" do
      post_care_plan(parent)

      expect(profile.reload.care_emergency_plan_pdf).to be_attached
      expect(profile.care_plan_pdf).not_to be_attached
    end

    it "builds the care-only variant when asked" do
      post_care_plan(parent, variant: "care_only")

      expect(response).to have_http_status(:ok)
      expect(profile.reload.care_plan_pdf).to be_attached
      expect(profile.care_emergency_plan_pdf).not_to be_attached
    end

    it "allows an admin" do
      post_care_plan(admin)

      expect(response).to have_http_status(:ok)
    end

    # The care plan carries medications; the controller-wide owner guard is
    # what keeps it off a team member's screen.
    it "refuses the SLP supervisor with 403 not_owner" do
      post_care_plan(slp)

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("not_owner")
    end

    it "generates nothing for a non-owner" do
      expect(Communicators::GenerateCarePlan).not_to receive(:call)

      post_care_plan(slp)
    end

    it "refuses an unauthenticated request" do
      post "/api/profiles/#{profile.id}/care_plan"

      expect(response).to have_http_status(:unauthorized)
    end

    # The section picker's wire format. The frontend sends a comma-separated
    # string; the array form is what a form-encoded client would send, and both
    # have to mean the same thing.
    it "passes a comma-separated selection through to the generator" do
      expect(Communicators::GenerateCarePlan).to receive(:call)
        .with(profile, hash_including(sections: %w[meals sensory]))
        .and_call_original

      post_care_plan(parent, sections: "meals,sensory")

      expect(response).to have_http_status(:ok)
    end

    it "accepts the selection as an array" do
      expect(Communicators::GenerateCarePlan).to receive(:call)
        .with(profile, hash_including(sections: %w[meals sensory]))
        .and_call_original

      post_care_plan(parent, sections: %w[meals sensory])

      expect(response).to have_http_status(:ok)
    end

    # Absent means every section, which is what every caller sent before the
    # picker existed — so it must stay distinguishable from "none selected".
    it "passes nil when no selection is sent" do
      expect(Communicators::GenerateCarePlan).to receive(:call)
        .with(profile, hash_including(sections: nil))
        .and_call_original

      post_care_plan(parent)
    end

    # An emergency-only sheet, and the reason an empty selection is a request
    # rather than a missing one.
    it "builds the combined plan from emergency info alone when nothing is selected" do
      post_care_plan(parent, sections: "")

      expect(response).to have_http_status(:ok)
      expect(profile.reload.care_emergency_plan_pdf).to be_attached
    end

    it "answers no_care_info when a care-only selection resolves to nothing" do
      post_care_plan(parent, variant: "care_only", sections: "sensory")

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to eq("no_care_info")
      expect(profile.reload.care_plan_pdf).not_to be_attached
    end

    # A key the profile has no section for can only ever remove sections, so it
    # needs no validation and gets no error.
    it "ignores a section key the profile does not have" do
      post_care_plan(parent, variant: "care_only", sections: "meals,not_a_section")

      expect(response).to have_http_status(:ok)
      expect(profile.reload.care_plan_pdf).to be_attached
    end

    it "rejects an unknown variant rather than falling back to the combined plan" do
      post_care_plan(parent, variant: "everything")

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to eq("unknown_variant")
      expect(profile.reload.care_emergency_plan_pdf).not_to be_attached
    end
  end

  describe "the size param" do
    before { profile.update!(settings: care.merge(emergency)) }

    it "defaults to sheet" do
      post_care_plan(parent)

      expect(response).to have_http_status(:ok)
      expect(profile.reload.care_emergency_plan_pdf).to be_attached
      expect(profile.care_emergency_plan_half_pdf).not_to be_attached
    end

    it "builds the half size when asked" do
      post_care_plan(parent, size: "half")

      expect(response).to have_http_status(:ok)
      expect(profile.reload.care_emergency_plan_half_pdf).to be_attached
      expect(profile.care_emergency_plan_pdf).not_to be_attached
    end

    it "builds the wallet size when asked" do
      post_care_plan(parent, size: "wallet")

      expect(response).to have_http_status(:ok)
      expect(profile.reload.care_emergency_plan_wallet_pdf).to be_attached
    end

    it "rejects an unknown size" do
      post_care_plan(parent, size: "poster")

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to eq("unknown_size")
    end

    # care_only + wallet isn't offered — a wallet card with no emergency block
    # is a name, a photo, and five care lines, which isn't worth the paper.
    it "rejects care_only + wallet as unsupported rather than emitting it" do
      post_care_plan(parent, variant: "care_only", size: "wallet")

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to eq("unsupported_size")
      expect(profile.reload.care_plan_pdf).not_to be_attached
    end

    it "still offers care_only at the half size" do
      post_care_plan(parent, variant: "care_only", size: "half")

      expect(response).to have_http_status(:ok)
      expect(profile.reload.care_plan_half_pdf).to be_attached
    end
  end

  # Refusing beats emitting a sheet of empty headings, which reads as a finished
  # plan asserting this child needs nothing.
  describe "empty states" do
    it "refuses care_only when there is no care info" do
      profile.update!(settings: emergency)

      post_care_plan(parent, variant: "care_only")

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to eq("no_care_info")
    end

    it "refuses the combined plan when there is neither care nor emergency info" do
      profile.update!(settings: {})

      post_care_plan(parent)

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to eq("nothing_to_print")
    end

    # The combined plan is still worth printing on emergency info alone — that
    # is the hospital-bag case.
    it "builds the combined plan from emergency info alone" do
      profile.update!(settings: emergency)

      post_care_plan(parent)

      expect(response).to have_http_status(:ok)
    end

    it "builds the combined plan from care info alone" do
      profile.update!(settings: care)

      post_care_plan(parent)

      expect(response).to have_http_status(:ok)
    end
  end

  describe "the communicator payload" do
    before { profile.update!(settings: care.merge(emergency)) }

    it "carries no care plan URLs until one is generated" do
      view = account.reload.api_view(parent)

      expect(view).to have_key(:care_plan_url)
      expect(view[:care_plan_url]).to be_nil
      expect(view[:care_emergency_plan_url]).to be_nil
      expect(view[:care_plan_half_url]).to be_nil
      expect(view[:care_emergency_plan_half_url]).to be_nil
      expect(view[:care_emergency_plan_wallet_url]).to be_nil
    end

    it "carries no preview URLs until one is generated" do
      view = account.reload.api_view(parent)

      expect(view).to have_key(:care_plan_preview_url)
      expect(view[:care_plan_preview_url]).to be_nil
      expect(view[:care_emergency_plan_preview_url]).to be_nil
      expect(view[:care_plan_half_preview_url]).to be_nil
      expect(view[:care_emergency_plan_half_preview_url]).to be_nil
      expect(view[:care_emergency_plan_wallet_preview_url]).to be_nil
    end

    # The thumbnail arrives with the document, on the SAME payload the screen
    # refetches after a download — nothing has to ask for it separately.
    it "carries the preview URL alongside the document once generated" do
      post_care_plan(parent, size: "wallet")

      view = account.reload.api_view(parent)
      expect(view[:care_emergency_plan_wallet_url]).to be_present
      expect(view[:care_emergency_plan_wallet_preview_url]).to be_present
      expect(view[:care_emergency_plan_preview_url]).to be_nil
    end

    # Ten attachment lookups per communicator multiply across a dashboard, and
    # this serializer backs the list payloads.
    it "keeps the preview URLs off the list payload" do
      post_care_plan(parent)

      view = account.reload.index_api_view

      expect(view).not_to have_key(:care_emergency_plan_preview_url)
      expect(view).not_to have_key(:care_emergency_plan_url)
    end

    it "carries the URL once generated" do
      post_care_plan(parent, variant: "care_only")

      view = account.reload.api_view(parent)
      expect(view[:care_plan_url]).to eq("https://cdn.example.test/care-plan.pdf")
      expect(view[:care_emergency_plan_url]).to be_nil
    end

    it "carries the half and wallet URLs once those sizes are generated" do
      post_care_plan(parent, size: "half")
      post_care_plan(parent, size: "wallet")

      view = account.reload.api_view(parent)
      expect(view[:care_emergency_plan_half_url]).to eq("https://cdn.example.test/care-plan.pdf")
      expect(view[:care_emergency_plan_wallet_url]).to eq("https://cdn.example.test/care-plan.pdf")
    end
  end
end
