require "rails_helper"

# A per-controller sweep of the whole /admin namespace. The individual admin
# request specs each check one action; this checks that *every* route in the
# namespace is behind the gate, including ones added later. A new
# Admin::FooController that forgets to inherit Admin::ApplicationController
# fails here rather than shipping an open page.
RSpec.describe "Admin dashboard access control", type: :request do
  include Devise::Test::IntegrationHelpers

  # Every distinct controller reachable under /admin.
  def self.admin_routes
    Rails.application.routes.routes.filter_map do |route|
      path = route.path.spec.to_s.sub(/\(\.:format\)\z/, "")
      next unless path == "/admin" || path.start_with?("/admin/")

      controller = route.defaults[:controller]
      next unless controller

      { path: path, controller: controller, verb: route.verb }
    end
  end

  ADMIN_ROUTES = admin_routes.freeze

  it "has routes to sweep" do
    expect(ADMIN_ROUTES).not_to be_empty
  end

  describe "controller inheritance" do
    ADMIN_ROUTES.map { |r| r[:controller] }.uniq.each do |controller|
      it "#{controller} inherits the admin gate" do
        klass = "#{controller}_controller".camelize.constantize

        expect(klass.ancestors).to include(Admin::ApplicationController),
          "#{klass} is routed under /admin but does not inherit " \
          "Admin::ApplicationController, so authenticate_user!/require_admin! never run."
      end
    end
  end

  # GET pages with no dynamic segments can be hit directly, so assert the real
  # HTTP behavior too — inheritance alone wouldn't catch a stray
  # skip_before_action.
  describe "GET pages" do
    let(:gettable) do
      ADMIN_ROUTES.select { |r| r[:verb] == "GET" && !r[:path].include?(":") }
    end

    it "actually has pages to sweep" do
      # Without this the three examples below pass on an empty list.
      expect(gettable.size).to be >= 10
    end

    before do
      allow_any_instance_of(ActionView::Helpers::AssetTagHelper)
        .to receive(:stylesheet_link_tag).and_return("")
      allow_any_instance_of(ActionView::Helpers::AssetTagHelper)
        .to receive(:javascript_include_tag).and_return("")
    end

    it "redirects anonymous visitors to sign in" do
      gettable.each do |route|
        get route[:path]

        expect(response).to have_http_status(:redirect), "#{route[:path]} did not redirect"
        expect(response.location).to include("/users/sign_in"),
          "#{route[:path]} let an anonymous visitor through (went to #{response.location})"
      end
    end

    it "bounces a signed-in non-admin off every page" do
      sign_in create(:user, email: "not-an-admin@example.com")

      gettable.each do |route|
        get route[:path]

        expect(response).to have_http_status(:redirect), "#{route[:path]} did not redirect a non-admin"
        expect(response.location).not_to include("/admin"),
          "#{route[:path]} let a non-admin through (went to #{response.location})"
      end
    end

    it "lets an admin through" do
      sign_in create(:admin_user)

      gettable.each do |route|
        get route[:path]

        expect(response).not_to have_http_status(:unauthorized), "#{route[:path]} rejected an admin"
        expect(response.location.to_s).not_to include("/users/sign_in"),
          "#{route[:path]} sent an admin to sign in"
      end
    end
  end
end
