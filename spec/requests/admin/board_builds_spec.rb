require "rails_helper"

RSpec.describe "Admin::BoardBuilds (dashboard)", type: :request do
  include Devise::Test::IntegrationHelpers

  let!(:seed_admin) { User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID) }
  let(:admin) { create(:admin_user) }

  before do
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:stylesheet_link_tag).and_return("")
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:javascript_include_tag).and_return("")
    BuildAdminBoardJob.jobs.clear
  end

  def form_params(overrides = {})
    {
      name: "Playground",
      topic: "the playground",
      voice: "polly:kevin",
      columns: "2",
      rows: "2",
      words: "i | pronoun\nwant | verb\nmore | important_function\nswing | noun",
      commercial_safe_only: "1",
    }.merge(overrides)
  end

  def create_build(**overrides)
    AdminBoardBuild.create!(
      {
        created_by: admin,
        name: "Playground",
        voice: "polly:kevin",
        columns_count: 2,
        rows_count: 2,
        plan: { "tiles" => [{ "label" => "i", "part_of_speech" => "pronoun" }] },
      }.merge(overrides),
    )
  end

  def built_board(published: false)
    Board.create!(
      name: "Built Board",
      user: seed_admin,
      published: published,
      settings: { AdminBoardBuild::BUILDER_SETTING => true },
    )
  end

  describe "authorization" do
    it "redirects a signed-out visitor and writes nothing" do
      get admin_dashboard_board_builds_path
      expect(response).to redirect_to(new_user_session_path)

      expect { post preview_admin_dashboard_board_builds_path, params: form_params }
        .to not_change(AdminBoardBuild, :count).and not_change(Image, :count)
      expect(response).to redirect_to(new_user_session_path)

      expect { post admin_dashboard_board_builds_path, params: form_params }.not_to change(AdminBoardBuild, :count)
    end

    it "redirects a non-admin away from every action" do
      sign_in create(:user)
      build = create_build(board: built_board)

      get admin_dashboard_board_builds_path
      expect(response).to redirect_to(root_path)

      get new_admin_dashboard_board_build_path
      expect(response).to redirect_to(root_path)

      expect { post preview_admin_dashboard_board_builds_path, params: form_params }.not_to change(Image, :count)
      expect(response).to redirect_to(root_path)

      expect { post admin_dashboard_board_builds_path, params: form_params }.not_to change(AdminBoardBuild, :count)
      expect(response).to redirect_to(root_path)

      post publish_admin_dashboard_board_build_path(build)
      expect(response).to redirect_to(root_path)
      expect(build.board.reload.published).to be(false)
    end

    it "lets an admin in" do
      sign_in admin
      get new_admin_dashboard_board_build_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /admin/board_builds/draft" do
    let(:drafted) do
      [
        { label: "I", part_of_speech: "pronoun" },
        { label: "want", part_of_speech: "verb" },
        { label: "more", part_of_speech: "social" },
        { label: "swing", part_of_speech: "noun" },
      ]
    end

    before do
      sign_in admin
      allow_any_instance_of(Boards::AdminBuilder::WordListDrafter).to receive(:call).and_return(drafted)
    end

    # The draft only ever populates the form — it is never fed to a preview or
    # a build on its own.
    it "fills the word list and writes nothing" do
      expect { post draft_admin_dashboard_board_builds_path, params: form_params(words: "") }
        .to not_change(Board, :count)
        .and not_change(Image, :count)
        .and not_change(AdminBoardBuild, :count)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("I | pronoun")
      expect(response.body).to include("swing | noun")
      expect(response.body).to include("Drafted 4 words")
    end

    it "keeps everything else the admin already typed" do
      post draft_admin_dashboard_board_builds_path,
           params: form_params(words: "", name: "Playtime", audience: "a preschooler")

      expect(response.body).to include("Playtime")
      expect(response.body).to include("a preschooler")
    end

    it "passes the topic, grid and audience to the drafter" do
      expect(Boards::AdminBuilder::WordListDrafter).to receive(:new)
        .with(topic: "the playground", columns: 2, rows: 2, audience: "a preschooler")
        .and_call_original

      post draft_admin_dashboard_board_builds_path, params: form_params(audience: "a preschooler")
    end

    it "says so when the draft comes back short of the grid" do
      allow_any_instance_of(Boards::AdminBuilder::WordListDrafter).to receive(:call).and_return(drafted.first(2))

      post draft_admin_dashboard_board_builds_path, params: form_params(words: "")

      expect(response.body).to include("Drafted 2 of 4 words")
    end

    it "refuses to draft without a topic" do
      post draft_admin_dashboard_board_builds_path, params: form_params(topic: "")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Give the board a topic to draft from")
    end

    it "does not require a name — a board can be drafted before it is named" do
      post draft_admin_dashboard_board_builds_path, params: form_params(name: "", words: "")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("I | pronoun")
    end

    it "surfaces a generation failure without losing the form" do
      allow_any_instance_of(Boards::AdminBuilder::WordListDrafter).to receive(:call)
        .and_raise(Boards::AdminBuilder::WordListDrafter::GenerationError, "OpenAI returned no content")

      post draft_admin_dashboard_board_builds_path, params: form_params

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Couldn&#39;t draft a word list")
      expect(response.body).to include("Playground")
    end

    it "is closed to non-admins" do
      sign_in create(:user)
      post draft_admin_dashboard_board_builds_path, params: form_params
      expect(response).to redirect_to(root_path)
    end
  end

  describe "POST /admin/board_builds/preview" do
    before { sign_in admin }

    # The rail this whole two-step flow exists for. ImageResolver.resolve_all
    # creates a blank Image for any unmatched label, so the Image assertion is
    # the one that actually catches a regression.
    it "writes nothing at all" do
      expect { post preview_admin_dashboard_board_builds_path, params: form_params }
        .to not_change(Board, :count)
        .and not_change(Image, :count)
        .and not_change(AdminBoardBuild, :count)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Review the art")
    end

    it "shows every authored word in the review grid" do
      post preview_admin_dashboard_board_builds_path, params: form_params

      %w[i want more swing].each { |label| expect(response.body).to include(label) }
    end

    it "reports labels with no library art as needing generation" do
      post preview_admin_dashboard_board_builds_path, params: form_params

      expect(response.body).to include("will be generated")
      expect(response.body).to include("0%")
    end
  end

  describe "validation" do
    before { sign_in admin }

    it "rejects a tile count that doesn't fill the grid and preserves what was typed" do
      params = form_params(rows: "3")

      expect { post preview_admin_dashboard_board_builds_path, params: params }
        .to not_change(Board, :count).and not_change(Image, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("needs exactly 6")
      expect(response.body).to include("Playground")
      expect(response.body).to include("swing | noun")
    end

    it "accepts a partial last row when the escape hatch is ticked" do
      post preview_admin_dashboard_board_builds_path, params: form_params(rows: "3", allow_partial_row: "1")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Review the art")
    end

    it "rejects duplicate words" do
      post preview_admin_dashboard_board_builds_path,
           params: form_params(words: "i | pronoun\nwant | verb\nwant | verb\nswing | noun")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Duplicate words: want")
    end

    it "rejects an unknown part of speech" do
      post preview_admin_dashboard_board_builds_path,
           params: form_params(words: "i | pronoun\nwant | gerund\nmore | verb\nswing | noun")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Unknown part of speech: gerund")
    end

    it "rejects a blank name" do
      expect { post admin_dashboard_board_builds_path, params: form_params(name: "") }
        .not_to change(AdminBoardBuild, :count)
      expect(response.body).to include("Give the board a name")
    end

    # VoiceService.normalize_voice waves through any string containing a colon,
    # so a typo would only fail later at audio synthesis.
    it "rejects a voice that isn't in the list" do
      expect { post admin_dashboard_board_builds_path, params: form_params(voice: "polly:kevn") }
        .not_to change(AdminBoardBuild, :count)
      expect(response.body).to include("Pick a voice from the list")
    end

    it "rejects an out-of-range grid" do
      post preview_admin_dashboard_board_builds_path, params: form_params(columns: "99")
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Columns must be between 1 and 12")
    end
  end

  describe "POST /admin/board_builds" do
    before { sign_in admin }

    it "records the plan, queues the build, and still writes no board yet" do
      expect { post admin_dashboard_board_builds_path, params: form_params }
        .to change(AdminBoardBuild, :count).by(1)
        .and not_change(Board, :count)

      build = AdminBoardBuild.last
      expect(build.status).to eq("pending")
      expect(build.name).to eq("Playground")
      expect(build.topic).to eq("the playground")
      expect(build.columns_count).to eq(2)
      expect(build.rows_count).to eq(2)
      expect(build.labels).to eq(%w[i want more swing])
      expect(build.tiles.map { |t| t["part_of_speech"] }).to eq(%w[pronoun verb important_function noun])
      expect(BuildAdminBoardJob.jobs.map { |job| job["args"].first }).to eq([build.id])
      expect(response).to redirect_to(admin_dashboard_board_build_path(build))
    end

    # The preview round trip is a hidden-field resubmit — create must re-derive
    # the plan rather than trusting it.
    it "re-validates the resubmitted plan instead of trusting the preview" do
      expect { post admin_dashboard_board_builds_path, params: form_params(words: "i | pronoun") }
        .not_to change(AdminBoardBuild, :count)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(BuildAdminBoardJob.jobs).to be_empty
    end

    it "keeps a plain word with no part of speech" do
      post admin_dashboard_board_builds_path, params: form_params(words: "i\nwant\nmore\nswing")

      expect(AdminBoardBuild.last.tiles.map { |t| t["part_of_speech"] }).to eq(%w[default default default default])
    end
  end

  describe "GET /admin/board_builds" do
    it "lists builds" do
      create_build(name: "Listed Build")
      sign_in admin

      get admin_dashboard_board_builds_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Listed Build")
    end
  end

  describe "GET /admin/board_builds/:id" do
    before { sign_in admin }

    it "shows a failed build with its error and the word list intact" do
      build = create_build(status: "failed", error_message: "boom")

      get admin_dashboard_board_build_path(build)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("failed")
      expect(response.body).to include("boom")
      expect(response.body).to include("i | pronoun")
    end

    it "surfaces the slug of the board it built" do
      board = built_board
      build = create_build(status: "complete", board: board)

      get admin_dashboard_board_build_path(build)

      expect(response.body).to include(board.slug)
    end
  end

  describe "publish / unpublish" do
    before { sign_in admin }

    it "publishes a board that has tiles" do
      board = built_board
      board.add_image(Image.create!(label: "i", user_id: seed_admin.id).id)
      build = create_build(status: "complete", board: board)

      post publish_admin_dashboard_board_build_path(build)

      expect(board.reload.published).to be(true)
      expect(response).to redirect_to(admin_dashboard_board_build_path(build))
    end

    it "refuses to publish an empty board" do
      build = create_build(status: "complete", board: built_board)

      post publish_admin_dashboard_board_build_path(build)

      expect(build.board.reload.published).to be(false)
      expect(flash[:alert]).to include("no tiles")
    end

    it "unpublishes a published board" do
      build = create_build(status: "complete", board: built_board(published: true))

      post unpublish_admin_dashboard_board_build_path(build)

      expect(build.board.reload.published).to be(false)
    end

    # The admin_builder marker is the scoping rail: a board this page didn't
    # create must be unreachable even if the build points at it.
    it "does not reach a board that wasn't created here" do
      other = create(:board, name: "Not A Built Board")
      build = create_build(status: "complete", board: other)

      post publish_admin_dashboard_board_build_path(build)

      expect(other.reload.published).to be_falsey
      expect(flash[:alert]).to include("No board to publish")
    end

    it "redirects when the build id is unknown" do
      post publish_admin_dashboard_board_build_path(id: 0)

      expect(response).to redirect_to(admin_dashboard_board_builds_path)
      expect(flash[:alert]).to include("not found")
    end
  end

  describe "DELETE /admin/board_builds/:id" do
    before { sign_in admin }

    it "deletes an unpublished build and its board" do
      build = create_build(status: "complete", board: built_board)

      expect { delete admin_dashboard_board_build_path(build) }
        .to change(AdminBoardBuild, :count).by(-1)
        .and change(Board, :count).by(-1)
      expect(response).to redirect_to(admin_dashboard_board_builds_path)
    end

    it "refuses to delete a published board" do
      build = create_build(status: "complete", board: built_board(published: true))

      expect { delete admin_dashboard_board_build_path(build) }.not_to change(AdminBoardBuild, :count)
      expect(flash[:alert]).to include("unpublish")
    end
  end

  describe "when no default admin exists" do
    it "refuses to build rather than seeding a board under the wrong owner" do
      seed_admin.destroy
      sign_in admin

      get new_admin_dashboard_board_build_path

      expect(response).to redirect_to(admin_root_path)
      expect(flash[:alert]).to include("No default admin user configured")
    end
  end
end
