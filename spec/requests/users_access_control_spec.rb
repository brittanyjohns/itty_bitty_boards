require "rails_helper"

# The legacy HTML admin lives under /users, outside the /admin namespace:
# /users and /users/admin list every account, and /users/:id renders one
# account's email, token balance, boards, menus and images.
#
# Those *pages* are already dead — their templates reference routes that no
# longer exist (boards_path, products_path, set_next_words_images_path), so
# they raise on render for admins too. The write actions are not dead: #update
# and #remove_user_doc redirect instead of rendering, and before this gate any
# signed-in user could point them at any other account.
#
# So the assertions below are about the gate, not the templates: a denied
# caller must be redirected to root and must not mutate anything. The
# allowed-caller cases assert only that the gate let them past, since what
# happens next is a pre-existing template failure.
RSpec.describe "UsersController access control", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:admin_user) }
  let(:owner) { create(:user, email: "owner@example.com") }
  let(:intruder) { create(:user, email: "intruder@example.com") }

  describe "the account-listing pages" do
    %w[/users /users/admin].each do |path|
      it "redirects an anonymous visitor from #{path} to sign in" do
        get path

        expect(response).to redirect_to(%r{/users/sign_in})
      end

      it "bounces a signed-in non-admin off #{path}" do
        sign_in intruder

        get path

        expect(response).to redirect_to(root_url)
        expect(flash[:alert]).to be_present
      end
    end

    it "does not leak another account's email through the listing" do
      owner
      sign_in intruder

      get "/users/admin"

      expect(response.body).not_to include(owner.email)
    end
  end

  describe "GET /users/:id" do
    it "does not leak another user's profile" do
      sign_in intruder

      get user_path(owner)

      expect(response).to redirect_to(root_url)
      expect(response.body).not_to include(owner.email)
    end

    # No allow-path example here: #show renders the dead template and raises
    # before it can assert anything. #show, #edit and #update share one
    # before_action, so the self/admin allow paths are covered by the PATCH
    # examples below.
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
