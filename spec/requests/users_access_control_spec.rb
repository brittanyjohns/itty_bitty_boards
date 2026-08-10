require "rails_helper"

# What's left of the legacy HTML surface under /users is the self-service
# profile: /users/:id renders one account's email, token balance and content
# counts, and #update / #remove_user_doc write. The account-listing pages
# (/users, /users/admin) are gone — see spec/requests/users_spec.rb for the
# routing assertions; admin listings live in the /admin namespace now.
#
# The assertions below are about the gate: a denied caller must be redirected
# to root, must see nothing of the target account, and must not mutate
# anything.
RSpec.describe "UsersController access control", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:admin_user) }
  let(:owner) { create(:user, email: "owner@example.com") }
  let(:intruder) { create(:user, email: "intruder@example.com") }

  before do
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:stylesheet_link_tag).and_return("")
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:javascript_include_tag).and_return("")
  end

  describe "GET /users/:id" do
    it "redirects an anonymous visitor to sign in" do
      get user_path(owner)

      expect(response).to redirect_to(%r{/users/sign_in})
    end

    it "does not leak another user's profile" do
      sign_in intruder

      get user_path(owner)

      expect(response).to redirect_to(root_url)
      expect(response.body).not_to include(owner.email)
    end

    it "lets a user see their own profile" do
      sign_in owner

      get user_path(owner)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(owner.email)
    end

    it "lets an admin see another user's profile" do
      sign_in admin

      get user_path(owner)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include(owner.email)
    end
  end

  describe "PATCH /users/:id" do
    it "refuses to let one user edit another" do
      sign_in intruder
      original = owner.name

      get edit_user_path(owner)
      expect(response).to redirect_to(root_url)

      patch user_path(owner), params: { user: { name: "Renamed By Intruder" } }

      expect(response).to redirect_to(root_url)
      expect(owner.reload.name).to eq(original)
    end

    it "lets a user edit their own profile" do
      sign_in owner

      patch user_path(owner), params: { user: { name: "Renamed By Self" } }

      expect(owner.reload.name).to eq("Renamed By Self")
    end

    it "lets an admin edit another user" do
      sign_in admin

      patch user_path(owner), params: { user: { name: "Renamed By Admin" } }

      expect(owner.reload.name).to eq("Renamed By Admin")
    end
  end

  describe "DELETE /users/:id/remove_user_doc" do
    # No :user_doc factory — build the join row directly.
    let(:user_doc) { UserDoc.create!(user: owner, doc: create(:doc, user: owner)) }

    it "refuses to let another user destroy it" do
      sign_in intruder

      delete remove_user_doc_user_path(user_doc)

      expect(response).to redirect_to(root_url)
      expect(UserDoc.exists?(user_doc.id)).to be(true)
    end

    it "lets the owner destroy their own" do
      sign_in owner

      delete remove_user_doc_user_path(user_doc)

      expect(UserDoc.exists?(user_doc.id)).to be(false)
    end

    it "lets an admin destroy it" do
      sign_in admin

      delete remove_user_doc_user_path(user_doc)

      expect(UserDoc.exists?(user_doc.id)).to be(false)
    end
  end
end
