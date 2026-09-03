require "rails_helper"

RSpec.describe "API::ClinicianApplications", type: :request do
  let(:user) { FactoryBot.create(:user) }

  let(:valid_params) do
    {
      clinician_application: {
        full_name: "Alex Rivera",
        credential_type: "slp",
        license_id: "SLP-12345",
        workplace: "Sunrise Elementary",
      },
    }
  end

  describe "POST /api/clinician_applications" do
    it "creates a pending application and emails a confirmation" do
      expect(ClinicianMailer).to receive(:application_received_email).and_return(double(deliver_later: true))

      expect {
        post "/api/clinician_applications", params: valid_params, headers: auth_headers(user)
      }.to change { user.clinician_applications.count }.by(1)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["application"]["status"]).to eq("pending")
      expect(body["application"]["credential_type"]).to eq("slp")
    end

    it "notifies an admin alongside the applicant confirmation" do
      allow(ClinicianMailer).to receive(:application_received_email).and_return(double(deliver_later: true))
      expect(AdminMailer).to receive(:new_clinician_application_email).and_return(double(deliver_later: true))

      post "/api/clinician_applications", params: valid_params, headers: auth_headers(user)

      expect(response).to have_http_status(:created)
    end

    # The applicant has already filled in the form; a mailer blowing up must
    # not take the application down with it.
    it "still creates the application when the admin notification raises" do
      allow(ClinicianMailer).to receive(:application_received_email).and_return(double(deliver_later: true))
      allow(AdminMailer).to receive(:new_clinician_application_email).and_raise(StandardError, "smtp down")

      expect {
        post "/api/clinician_applications", params: valid_params, headers: auth_headers(user)
      }.to change { user.clinician_applications.count }.by(1)

      expect(response).to have_http_status(:created)
    end

    it "allows only one pending application at a time" do
      allow(ClinicianMailer).to receive(:application_received_email).and_return(double(deliver_later: true))
      post "/api/clinician_applications", params: valid_params, headers: auth_headers(user)
      expect(response).to have_http_status(:created)

      expect {
        post "/api/clinician_applications", params: valid_params, headers: auth_headers(user)
      }.not_to change { user.clinician_applications.count }
      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to eq("application_pending")
    end

    it "requires authentication (401)" do
      post "/api/clinician_applications", params: valid_params
      expect(response).to have_http_status(:unauthorized)
    end

    it "422s on invalid params (missing full_name)" do
      bad = { clinician_application: { credential_type: "slp" } }
      post "/api/clinician_applications", params: bad, headers: auth_headers(user)
      expect(response).to have_http_status(:unprocessable_content)
    end

    # Older clients (and the web app, before the canonical slugs shipped) send
    # display labels. Normalization means those submissions are stored
    # correctly rather than newly rejected by the inclusion validation.
    it "normalizes a display-label credential_type instead of rejecting it" do
      allow(ClinicianMailer).to receive(:application_received_email).and_return(double(deliver_later: true))

      post "/api/clinician_applications",
           params: { clinician_application: valid_params[:clinician_application].merge(credential_type: "AT specialist") },
           headers: auth_headers(user)

      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)["application"]["credential_type"]).to eq("at_specialist")
    end

    # The license field is the barrier the /clinicians/apply page put in front of
    # the applicants it recruits by name. Backend half of the fix: required only
    # where a license genuinely exists, placeholders refused there, and a
    # free-text alternative accepted everywhere else.
    describe "license requirements" do
      before { allow(ClinicianMailer).to receive(:application_received_email).and_return(double(deliver_later: true)) }

      it "422s an SLP application whose license is the literal string N/A" do
        expect {
          post "/api/clinician_applications",
               params: { clinician_application: valid_params[:clinician_application].merge(license_id: "N/A") },
               headers: auth_headers(user)
        }.not_to change { user.clinician_applications.count }

        expect(response).to have_http_status(:unprocessable_content)
        body = JSON.parse(response.body)
        expect(body["message"]).to include("doesn't look like")
        # Field-keyed, so the form can put the refusal under the license input
        # rather than in a page-level banner — which is where it has to appear
        # for the alternative it offers to make sense.
        expect(body["errors"]).to have_key("license_id")
      end

      it "lets an AT specialist apply without inventing a license number" do
        expect {
          post "/api/clinician_applications",
               params: { clinician_application: {
                 full_name: "Ray Okafor",
                 credential_type: "at_specialist",
                 workplace: "Northside USD",
                 verification_note: "District AT lead — verify with my director, or my RESNA ATP is in progress.",
               } },
               headers: auth_headers(user)
        }.to change { user.clinician_applications.count }.by(1)

        expect(response).to have_http_status(:created)
        application = JSON.parse(response.body)["application"]
        expect(application["license_id"]).to be_nil
        expect(application["license_required"]).to be(false)
        expect(application["verification_note"]).to include("District AT lead")
      end

      it "drops a placeholder rather than storing it when no license is required" do
        post "/api/clinician_applications",
             params: { clinician_application: {
               full_name: "Ray Okafor", credential_type: "other", license_id: "N/A",
             } },
             headers: auth_headers(user)

        expect(response).to have_http_status(:created)
        expect(JSON.parse(response.body)["application"]["license_id"]).to be_nil
      end
    end

    # The account is created by the signup form and the application by this
    # endpoint, so without this the clinician-apply funnel is indistinguishable
    # from any other web signup and can't be measured.
    describe "signup attribution" do
      before { allow(ClinicianMailer).to receive(:application_received_email).and_return(double(deliver_later: true)) }

      it "stamps clinician_apply on a first application from a fresh account" do
        user.update!(settings: (user.settings || {}).merge("signup_method" => "standard"))

        post "/api/clinician_applications", params: valid_params, headers: auth_headers(user)

        expect(response).to have_http_status(:created)
        expect(user.reload.settings["signup_method"]).to eq("clinician_apply")
      end

      # Provenance that a later action can rewrite is worth nothing. An account
      # that has been around for a while applied AFTER signing up some other way.
      it "leaves an established account's signup_method alone" do
        user.update!(settings: (user.settings || {}).merge("signup_method" => "standard"))
        user.update_column(:created_at, 3.days.ago)

        post "/api/clinician_applications", params: valid_params, headers: auth_headers(user)

        expect(response).to have_http_status(:created)
        expect(user.reload.settings["signup_method"]).to eq("standard")
      end

      it "never overwrites a method the signup request already recorded" do
        user.update!(settings: (user.settings || {}).merge("signup_method" => "google"))

        post "/api/clinician_applications", params: valid_params, headers: auth_headers(user)

        expect(response).to have_http_status(:created)
        expect(user.reload.settings["signup_method"]).to eq("google")
      end
    end

    # The web client sends a flat JSON body; Rails' ParamsWrapper (enabled by
    # load_defaults 8.0) wraps it under `clinician_application`. Pinned here so
    # a future initializer that turns wrapping off can't silently 400 the
    # apply form.
    it "accepts a flat JSON body via ParamsWrapper" do
      allow(ClinicianMailer).to receive(:application_received_email).and_return(double(deliver_later: true))

      post "/api/clinician_applications",
           params: valid_params[:clinician_application].to_json,
           headers: auth_headers(user).merge("CONTENT_TYPE" => "application/json")

      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)["application"]["full_name"]).to eq("Alex Rivera")
    end
  end

  describe "GET /api/clinician_applications/mine" do
    it "returns the user's latest application" do
      app = user.clinician_applications.create!(full_name: "A", credential_type: "ot", license_id: "OT-9911", status: "denied")
      get "/api/clinician_applications/mine", headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["application"]["id"]).to eq(app.id)
    end

    it "returns null when the user has no application" do
      get "/api/clinician_applications/mine", headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["application"]).to be_nil
    end
  end
end
