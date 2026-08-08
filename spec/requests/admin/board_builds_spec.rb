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
      tile_count: "4",
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
        tile_count: 4,
        plan: { "tiles" => [{ "label" => "i", "part_of_speech" => "pronoun" }] },
      }.merge(overrides),
    )
  end

  def built_board(published: false, name: "Built Board")
    Board.create!(
      name: name,
      slug: name.parameterize,
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

  # Turbo Drive discards a 2xx form response that isn't a redirect ("Form
  # responses must redirect to another location") — so every action this form
  # posts to that renders instead of redirecting (suggest, draft, preview)
  # silently does nothing in a browser unless the form opts out.
  describe "the authoring form opts out of Turbo" do
    before { sign_in admin }

    it "marks the form on the new page" do
      get new_admin_dashboard_board_build_path

      expect(response.body).to include('data-turbo="false"')
    end

    it "marks the form re-rendered under the art preview" do
      post preview_admin_dashboard_board_builds_path, params: form_params

      expect(response.body).to include('data-turbo="false"')
    end
  end

  describe "child pages" do
    before { sign_in admin }

    def set_params(overrides = {})
      form_params(
        words: "i | pronoun\nwant | verb\nmore | social\nFood | noun | >food",
        children: {
          "0" => {
            key: "food", name: "Food", columns: "", tile_count: "",
            words: "apple | noun\nbanana | noun\nhungry | adjective\nback | social | >__root__",
          },
        },
      ).merge(overrides)
    end

    it "previews every page separately and still writes nothing" do
      expect { post preview_admin_dashboard_board_builds_path, params: set_params }
        .to not_change(Board, :count)
        .and not_change(Image, :count)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Main board")
      expect(response.body).to include("Page “food”")
      expect(response.body).to include("opens “food”")
    end

    it "stores the pages and the links on the build" do
      post admin_dashboard_board_builds_path, params: set_params

      build = AdminBoardBuild.last
      expect(build.children.map { |child| child["key"] }).to eq(["food"])
      expect(build.children.first["name"]).to eq("Food")
      expect(build.tiles.last).to include("label" => "Food", "links_to" => "food")
      expect(build.children.first["tiles"].last).to include("links_to" => "__root__")
      expect(build.labels).to include("apple", "hungry")
    end

    # The token is found by its `>`, not by its position, so a tile can link
    # without being forced to fill in a part of speech or tile text first.
    it "reads the link token wherever it appears in the line" do
      post admin_dashboard_board_builds_path,
           params: set_params(words: "i | pronoun\nwant | verb\nmore | social\nFood | >food")

      tile = AdminBoardBuild.last.tiles.last
      expect(tile["links_to"]).to eq("food")
      expect(tile["part_of_speech"]).to eq("default")
      expect(tile).not_to have_key("display_label")
    end

    it "keeps the remaining fields positional once the link token is removed" do
      post admin_dashboard_board_builds_path,
           params: set_params(words: "i | pronoun\nwant | verb\nmore | social\nFood | noun | Food page | >food")

      tile = AdminBoardBuild.last.tiles.last
      expect(tile["links_to"]).to eq("food")
      expect(tile["part_of_speech"]).to eq("noun")
      expect(tile["display_label"]).to eq("Food page")
    end

    it "drops a wholly blank page block rather than failing on it" do
      params = set_params
      params[:children]["1"] = { key: "", name: "", columns: "", tile_count: "", words: "  " }

      expect { post admin_dashboard_board_builds_path, params: params }
        .to change(AdminBoardBuild, :count).by(1)
      expect(AdminBoardBuild.last.children.size).to eq(1)
    end

    it "rejects a tile pointing at a page that doesn't exist" do
      params = set_params(words: "i | pronoun\nwant | verb\nmore | social\nFood | noun | >nope")

      expect { post admin_dashboard_board_builds_path, params: params }.not_to change(AdminBoardBuild, :count)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("which doesn&#39;t exist")
    end

    it "rejects a page whose grid differs from the main board's" do
      params = set_params
      params[:children]["0"] = params[:children]["0"].merge(columns: "3", tile_count: "9",
                                                            words: (1..9).map { |i| "word#{i} | noun" }.join("\n"))

      expect { post admin_dashboard_board_builds_path, params: params }.not_to change(AdminBoardBuild, :count)
      expect(response.body).to include("differs from the main board")
    end

    it "allows a different grid when the escape hatch is ticked" do
      params = set_params(allow_mixed_grids: "1")
      params[:children]["0"] = params[:children]["0"].merge(columns: "3", tile_count: "9",
                                                            words: (1..9).map { |i| "word#{i} | noun" }.join("\n"))

      expect { post admin_dashboard_board_builds_path, params: params }.to change(AdminBoardBuild, :count).by(1)
    end

    it "rejects a duplicate page key" do
      params = set_params
      params[:children]["1"] = params[:children]["0"]

      expect { post admin_dashboard_board_builds_path, params: params }.not_to change(AdminBoardBuild, :count)
      expect(response.body).to include("Duplicate page keys: food")
    end

    it "rejects an out-of-range page grid" do
      params = set_params
      params[:children]["0"] = params[:children]["0"].merge(columns: "99")

      post admin_dashboard_board_builds_path, params: params
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Food: columns must be between 1 and 12")
    end

    it "preserves the submitted pages when something else fails validation" do
      post preview_admin_dashboard_board_builds_path, params: set_params(name: "")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("hungry | adjective")
      expect(response.body).to include("Food")
    end
  end

  describe "POST /admin/board_builds/suggest" do
    before do
      sign_in admin
      allow_any_instance_of(Boards::AdminBuilder::ContextSuggester).to receive(:call)
        .and_return({ name: "At the Playground", topic: "the playground", audience: "a preschooler" })
    end

    it "fills in every blank field and writes nothing" do
      expect { post suggest_admin_dashboard_board_builds_path, params: form_params(topic: "", audience: "") }
        .to not_change(Board, :count)
        .and not_change(Image, :count)
        .and not_change(AdminBoardBuild, :count)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("the playground")
      expect(response.body).to include("a preschooler")
      expect(response.body).to include("Filled in what was blank")
    end

    it "keeps the rest of the form" do
      post suggest_admin_dashboard_board_builds_path,
           params: form_params(topic: "", audience: "", name: "Playtime")

      expect(response.body).to include("Playtime")
      expect(response.body).to include("swing | noun")
    end

    it "reads the name, topic and words already typed" do
      expect(Boards::AdminBuilder::ContextSuggester).to receive(:new)
        .with(name: "Playground", topic: "", words: a_string_including("swing"))
        .and_call_original

      post suggest_admin_dashboard_board_builds_path, params: form_params(name: "Playground", topic: "", audience: "")
    end

    # The whole point: an admin shouldn't have to invent a board name first.
    it "names a board that has only a topic" do
      post suggest_admin_dashboard_board_builds_path,
           params: form_params(name: "", audience: "", words: "")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("At the Playground")
    end

    it "leaves a name the admin typed alone" do
      post suggest_admin_dashboard_board_builds_path, params: form_params(name: "My Board", topic: "", audience: "")

      expect(response.body).to include("My Board")
      expect(response.body).not_to include("At the Playground")
    end

    it "leaves a value the admin already typed alone" do
      post suggest_admin_dashboard_board_builds_path, params: form_params(audience: "a teenager")

      expect(response.body).to include("a teenager")
      expect(response.body).not_to include("a preschooler")
    end

    it "refuses when there is nothing at all to work from" do
      post suggest_admin_dashboard_board_builds_path, params: form_params(name: "", topic: "", words: "")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Give the board a name, a topic, or some words")
    end

    it "surfaces a generation failure without losing the form" do
      allow_any_instance_of(Boards::AdminBuilder::ContextSuggester).to receive(:call)
        .and_raise(Boards::AdminBuilder::ContextSuggester::GenerationError, "OpenAI returned no content")

      post suggest_admin_dashboard_board_builds_path, params: form_params(topic: "")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Couldn&#39;t suggest a topic")
      expect(response.body).to include("Playground")
    end

    it "is closed to non-admins" do
      sign_in create(:user)
      post suggest_admin_dashboard_board_builds_path, params: form_params
      expect(response).to redirect_to(root_path)
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
      # A blank name or topic makes draft infer first, so nothing here can
      # reach the real API by accident.
      allow_any_instance_of(Boards::AdminBuilder::ContextSuggester).to receive(:call)
        .and_return({ name: "At the Playground", topic: "the playground", audience: "an early communicator" })
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

    it "passes the topic, tile count and audience to the drafter" do
      expect(Boards::AdminBuilder::WordListDrafter).to receive(:new)
        .with(topic: "the playground", tile_count: 4, audience: "a preschooler")
        .and_call_original

      post draft_admin_dashboard_board_builds_path, params: form_params(audience: "a preschooler")
    end

    it "says so when the draft comes back short of the grid" do
      allow_any_instance_of(Boards::AdminBuilder::WordListDrafter).to receive(:call).and_return(drafted.first(2))

      post draft_admin_dashboard_board_builds_path, params: form_params(words: "")

      expect(response.body).to include("Drafted 2 of 4 words")
    end

    # Topic and audience steer the draft and, later, the art prompts, so a
    # blank one is inferred rather than being a prerequisite.
    it "works out a blank topic and audience before drafting" do
      allow_any_instance_of(Boards::AdminBuilder::ContextSuggester).to receive(:call)
        .and_return({ name: "At the Playground", topic: "the playground", audience: "a preschooler" })

      expect(Boards::AdminBuilder::WordListDrafter).to receive(:new)
        .with(hash_including(topic: "the playground", audience: "a preschooler"))
        .and_call_original

      post draft_admin_dashboard_board_builds_path,
           params: form_params(topic: "", audience: "", name: "At the Playground", words: "")

      expect(response).to have_http_status(:ok)
    end

    # Preview and build require a name, so drafting fills a blank one rather
    # than handing back a word list that can't be submitted.
    it "names an unnamed board while drafting it" do
      allow_any_instance_of(Boards::AdminBuilder::ContextSuggester).to receive(:call)
        .and_return({ name: "At the Playground", topic: "the playground", audience: "a preschooler" })

      post draft_admin_dashboard_board_builds_path, params: form_params(name: "", words: "")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("At the Playground")
      expect(response.body).to include("I | pronoun")
    end

    it "never overwrites a topic the admin typed" do
      expect(Boards::AdminBuilder::ContextSuggester).not_to receive(:new)
      expect(Boards::AdminBuilder::WordListDrafter).to receive(:new)
        .with(hash_including(topic: "the playground", audience: "a preschooler"))
        .and_call_original

      post draft_admin_dashboard_board_builds_path, params: form_params(audience: "a preschooler", words: "")
    end

    it "fills a blank topic but keeps an audience the admin typed" do
      allow_any_instance_of(Boards::AdminBuilder::ContextSuggester).to receive(:call)
        .and_return({ name: "Playground", topic: "the playground", audience: "someone else" })

      expect(Boards::AdminBuilder::WordListDrafter).to receive(:new)
        .with(hash_including(topic: "the playground", audience: "a teenager"))
        .and_call_original

      post draft_admin_dashboard_board_builds_path, params: form_params(topic: "", audience: "a teenager", words: "")
    end

    # Audience is optional to the drafter, so a known topic means no second
    # round trip just to fill it in.
    it "does not spend a call working out a blank audience when the topic is known" do
      expect(Boards::AdminBuilder::ContextSuggester).not_to receive(:new)

      post draft_admin_dashboard_board_builds_path, params: form_params(audience: "", words: "")

      expect(response).to have_http_status(:ok)
    end

    it "refuses to draft with neither a name nor a topic" do
      post draft_admin_dashboard_board_builds_path, params: form_params(topic: "", name: "", words: "")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Give the board a name or a topic to draft from")
    end

    it "does not require a name — a board can be drafted from a topic alone" do
      post draft_admin_dashboard_board_builds_path, params: form_params(name: "", words: "")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("I | pronoun")
    end

    it "surfaces a failure to work out the topic" do
      allow_any_instance_of(Boards::AdminBuilder::ContextSuggester).to receive(:call)
        .and_raise(Boards::AdminBuilder::ContextSuggester::GenerationError, "OpenAI returned no content")

      post draft_admin_dashboard_board_builds_path, params: form_params(topic: "", name: "Playground")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Couldn&#39;t work out the topic")
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

  describe "POST /admin/board_builds/add_words" do
    let(:new_tiles) do
      [
        { label: "slide", part_of_speech: "noun" },
        { label: "go", part_of_speech: "verb" },
      ]
    end

    before do
      sign_in admin
      allow_any_instance_of(Boards::AdminBuilder::WordListDrafter).to receive(:call).and_return(new_tiles)
    end

    # form_params already has 4 words; asking for 6 leaves 2 missing.
    it "appends only the missing words and writes nothing" do
      expect { post add_words_admin_dashboard_board_builds_path, params: form_params(tile_count: "6") }
        .to not_change(Board, :count)
        .and not_change(Image, :count)
        .and not_change(AdminBoardBuild, :count)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("i | pronoun")
      expect(response.body).to include("swing | noun")
      expect(response.body).to include("slide | noun")
      expect(response.body).to include("go | verb")
      expect(response.body).to include("Added 2 words")
    end

    it "passes the missing count and the existing labels to the drafter, not the whole tile_count" do
      expect(Boards::AdminBuilder::WordListDrafter).to receive(:new)
        .with(topic: "the playground", tile_count: 2, audience: "", existing_labels: %w[i want more swing])
        .and_call_original

      post add_words_admin_dashboard_board_builds_path, params: form_params(tile_count: "6")
    end

    it "refuses when the list already meets the tile count" do
      expect(Boards::AdminBuilder::WordListDrafter).not_to receive(:new)

      post add_words_admin_dashboard_board_builds_path, params: form_params(tile_count: "4")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Already have 4 of 4 words")
    end

    it "says so when the top-up comes back short" do
      allow_any_instance_of(Boards::AdminBuilder::WordListDrafter).to receive(:call).and_return(new_tiles.first(1))

      post add_words_admin_dashboard_board_builds_path, params: form_params(tile_count: "6")

      expect(response.body).to include("Added 1 of 2 more words (5 of 6 so far)")
    end

    it "surfaces a generation failure without losing the form" do
      allow_any_instance_of(Boards::AdminBuilder::WordListDrafter).to receive(:call)
        .and_raise(Boards::AdminBuilder::WordListDrafter::GenerationError, "OpenAI returned no content")

      post add_words_admin_dashboard_board_builds_path, params: form_params(tile_count: "6")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Couldn&#39;t draft more words")
      expect(response.body).to include("i | pronoun")
    end

    it "is closed to non-admins" do
      sign_in create(:user)
      post add_words_admin_dashboard_board_builds_path, params: form_params(tile_count: "6")
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

    # The review grid used to be a hardcoded 6 columns, so a 4-wide board was
    # reviewed at a width it would never be used at.
    it "draws the review grid at the authored column count" do
      params = form_params(columns: "4", tile_count: "4", words: "i | pronoun\nwant | verb\nmore | important_function\nswing | noun")

      post preview_admin_dashboard_board_builds_path, params: params

      expect(response.body).to include("--cols: 4")
      expect(response.body).not_to include("lg:grid-cols-6")
    end

    it "draws each page of a mixed-grid set at its own column count" do
      params = form_params(
        columns: "2", tile_count: "4",
        words: "i | pronoun\nwant | verb\nmore | important_function\nFood | noun | >food",
        allow_mixed_grids: "1",
        children: { "0" => { key: "food", name: "Food", columns: "3", tile_count: "3", words: "apple\nbanana\nhungry" } },
      )

      post preview_admin_dashboard_board_builds_path, params: params

      expect(response.body).to include("--cols: 2")
      expect(response.body).to include("--cols: 3")
    end

    # Finding 1: the preview page's build-resubmit form is a separate <form>
    # from the authoring form, so description/tags must be threaded through
    # explicitly as hidden fields or they silently vanish on "Build this
    # board" — see app/views/admin/board_builds/preview.html.erb.
    it "carries description and tags through the build-resubmit form" do
      params = form_params(description: "A board for outdoor play.", tags: "playground, outdoor play")

      post preview_admin_dashboard_board_builds_path, params: params

      doc = Nokogiri::HTML::Document.parse(response.body)
      description_field = doc.at_css(%(input[type="hidden"][name="description"]))
      tags_field = doc.at_css(%(input[type="hidden"][name="tags"]))

      expect(description_field["value"]).to eq("A board for outdoor play.")
      expect(tags_field["value"]).to eq("playground, outdoor play")
    end
  end

  describe "validation" do
    before { sign_in admin }

    it "rejects a word list that doesn't match the tile count and preserves what was typed" do
      params = form_params(tile_count: "6")

      expect { post preview_admin_dashboard_board_builds_path, params: params }
        .to not_change(Board, :count).and not_change(Image, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("needs exactly 6")
      expect(response.body).to include("Playground")
      expect(response.body).to include("swing | noun")
    end

    # The escape hatch now governs the SIZE, not the word list: 3 tiles across
    # 2 columns is a partial last row, and the words still have to match it.
    it "accepts a tile count that doesn't fill whole rows when the escape hatch is ticked" do
      params = form_params(tile_count: "3", words: "i | pronoun\nwant | verb\nmore | important_function",
                           allow_partial_row: "1")

      post preview_admin_dashboard_board_builds_path, params: params

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Review the art")
    end

    it "rejects a tile count that leaves a partial last row without the escape hatch" do
      params = form_params(tile_count: "3", words: "i | pronoun\nwant | verb\nmore | important_function")

      post preview_admin_dashboard_board_builds_path, params: params

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("partial last row")
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
      expect(build.tile_count).to eq(4)
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

    # The app URL works before publishing; /pb/ does not, so an unpublished
    # build must not offer a public link that 404s.
    it "links the built board into the app in a new tab" do
      board = built_board
      build = create_build(status: "complete", board: board)

      get admin_dashboard_board_build_path(build)

      expect(response.body).to include("http://localhost:8100/boards/#{board.id}")
      expect(response.body).to include('target="_blank"')
      expect(response.body).not_to include("http://localhost:8100/pb/#{board.slug}")
    end

    it "links the public page too once the board is published" do
      board = built_board(published: true)
      build = create_build(status: "complete", board: board)

      get admin_dashboard_board_build_path(build)

      expect(response.body).to include("http://localhost:8100/pb/#{board.slug}")
    end

    it "links every page of a linked set" do
      root = built_board
      page = built_board(name: "Food page")
      build = create_build(status: "complete", board: root)
      build.update!(art_report: { "boards" => { "__root__" => root.id, "food" => page.id } })

      get admin_dashboard_board_build_path(build)

      expect(response.body).to include("http://localhost:8100/boards/#{page.id}")
    end

    # The tile grid mirrors the board's own lg layout, so what the review page
    # shows is what a communicator gets.
    it "draws the tile grid at the board's own column count" do
      board = built_board
      board.update!(large_screen_columns: 8)
      board.add_image(Image.create!(label: "i", user_id: seed_admin.id).id)
      build = create_build(status: "complete", board: board)

      get admin_dashboard_board_build_path(build)

      expect(response.body).to include("--cols: 8")
      expect(response.body).not_to include("lg:grid-cols-6")
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
    # Board#viewable_by? gates each board on its OWN published flag, so
    # publishing only the root leaves every folder tile 404ing for a visitor.
    context "a linked set" do
      def built_set
        root = built_board
        page = built_board(name: "Food page")
        [root, page].each { |board| board.add_image(Image.create!(label: "i", user_id: seed_admin.id).id) }
        build = create_build(status: "complete", board: root)
        build.update!(art_report: { "boards" => { "__root__" => root.id, "food" => page.id } })
        [build, root, page]
      end

      it "publishes every page, not just the root" do
        build, root, page = built_set

        post publish_admin_dashboard_board_build_path(build)

        expect(root.reload.published).to be(true)
        expect(page.reload.published).to be(true)
        expect(flash[:notice]).to include("and its 1 page")
      end

      it "unpublishes every page" do
        build, root, page = built_set
        [root, page].each { |board| board.update!(published: true) }

        post unpublish_admin_dashboard_board_build_path(build)

        expect(root.reload.published).to be(false)
        expect(page.reload.published).to be(false)
      end

      it "refuses to publish when any page is empty" do
        build, root, page = built_set
        page.board_images.destroy_all

        post publish_admin_dashboard_board_build_path(build)

        expect(root.reload.published).to be(false)
        expect(flash[:alert]).to include("Food page has no tiles")
      end

      it "deletes every page" do
        build, = built_set

        expect { delete admin_dashboard_board_build_path(build) }.to change(Board, :count).by(-2)
      end

      it "ignores a recorded page that isn't one of ours" do
        build, root, = built_set
        stranger = create(:board, name: "Not Ours")
        build.update!(art_report: { "boards" => { "__root__" => root.id, "x" => stranger.id } })

        post publish_admin_dashboard_board_build_path(build)

        expect(root.reload.published).to be(true)
        expect(stranger.reload.published).to be_falsey
      end
    end

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

  describe "POST draft_set" do
    before { sign_in admin }

    def stub_set_drafter(result)
      allow(Boards::AdminBuilder::SetDrafter).to receive(:new).and_return(
        instance_double(Boards::AdminBuilder::SetDrafter, call: result),
      )
    end

    let(:drafted) do
      {
        root_tiles: [
          { label: "I", part_of_speech: "pronoun" },
          { label: "Food", part_of_speech: "noun", links_to: "food" },
        ],
        children: [
          { key: "food", name: "Food",
            tiles: [{ label: "apple", part_of_speech: "noun" },
                    { label: "back", part_of_speech: "social", links_to: "__root__" }] },
        ],
      }
    end

    it "fills the root textarea with link tokens and renders the page block" do
      stub_set_drafter(drafted)

      post draft_set_admin_dashboard_board_builds_path,
           params: form_params(words: "", page_count: "1", columns: "1", tile_count: "2")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Food | noun | &gt;food")
      expect(response.body).to include("apple | noun")
      expect(response.body).to include("children[0][key]")
    end

    it "writes nothing" do
      stub_set_drafter(drafted)

      expect {
        post draft_set_admin_dashboard_board_builds_path,
             params: form_params(words: "", page_count: "1", columns: "1", tile_count: "2")
      }.to not_change(Board, :count).and not_change(Image, :count).and not_change(AdminBoardBuild, :count)
    end

    it "reports a generation failure without losing what was typed" do
      allow(Boards::AdminBuilder::SetDrafter).to receive(:new).and_raise(
        Boards::AdminBuilder::SetDrafter::GenerationError, "OpenAI returned no content",
      )

      post draft_set_admin_dashboard_board_builds_path,
           params: form_params(name: "Playground", page_count: "1")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Couldn&#39;t draft the set")
      expect(response.body).to include("Playground")
    end

    it "refuses to draft with nothing to work from" do
      post draft_set_admin_dashboard_board_builds_path,
           params: form_params(name: "", topic: "", words: "", page_count: "1")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("draft from")
    end

    it "warns rather than claiming success when the AI comes back short on pages" do
      stub_set_drafter(root_tiles: drafted[:root_tiles], children: [])

      post draft_set_admin_dashboard_board_builds_path,
           params: form_params(words: "", page_count: "2", columns: "1", tile_count: "2")

      expect(response).to have_http_status(:ok)
      expect(flash[:notice]).to match(/short|didn.t come back|asked for 2/i)
      expect(flash[:notice]).not_to eq("Drafted the main board and 0 pages. Edit them, then preview the art.")
    end
  end

  describe "POST describe" do
    before { sign_in admin }

    def stub_suggester(result)
      allow(Boards::AdminBuilder::MetadataSuggester).to receive(:new).and_return(
        instance_double(Boards::AdminBuilder::MetadataSuggester, call: result),
      )
    end

    it "fills the description and tags fields" do
      stub_suggester({ description: "A board for the playground.", tags: %w[playground outdoor] })

      post describe_admin_dashboard_board_builds_path, params: form_params

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("A board for the playground.")
      expect(response.body).to include("playground, outdoor")
    end

    it "writes nothing" do
      stub_suggester({ description: "A board.", tags: %w[playground] })

      expect { post describe_admin_dashboard_board_builds_path, params: form_params }
        .to not_change(Board, :count).and not_change(AdminBoardBuild, :count)
    end

    it "reports a generation failure without losing what was typed" do
      allow(Boards::AdminBuilder::MetadataSuggester).to receive(:new).and_raise(
        Boards::AdminBuilder::MetadataSuggester::GenerationError, "OpenAI returned no content",
      )

      post describe_admin_dashboard_board_builds_path, params: form_params(name: "Playground")

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("Couldn&#39;t suggest a description")
      expect(response.body).to include("Playground")
    end
  end

  describe "POST create with metadata" do
    before { sign_in admin }

    it "stores the description, normalized tags and audience on the build" do
      post admin_dashboard_board_builds_path, params: form_params(
        description: "  A board for the playground.  ",
        tags: " PlayGround , Outdoor   Play ,, playground ",
        audience: "an early communicator",
      )

      build = AdminBoardBuild.last
      expect(build.description).to eq("A board for the playground.")
      expect(build.tags).to eq(["playground", "outdoor play"])
      expect(build.audience).to eq("an early communicator")
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

  describe "PATCH update" do
    before { sign_in admin }

    it "updates the description and tags on the build and its root board" do
      board = built_board
      build = create_build(board: board, status: "complete")

      patch admin_dashboard_board_build_path(build),
            params: { description: "  A playground board.  ", tags: " PlayGround , outdoor play " }

      expect(response).to redirect_to(admin_dashboard_board_build_path(build))
      expect(build.reload.description).to eq("A playground board.")
      expect(build.tags).to eq(["playground", "outdoor play"])
      expect(board.reload.description).to eq("A playground board.")
      expect(board.tags).to eq(["playground", "outdoor play"])
    end

    it "clears both when submitted empty" do
      board = built_board
      board.update!(description: "old", tags: %w[old])
      build = create_build(board: board, status: "complete", description: "old", tags: %w[old])

      patch admin_dashboard_board_build_path(build), params: { description: "", tags: "" }

      expect(build.reload.description).to be_nil
      expect(build.tags).to eq([])
      expect(board.reload.description).to be_blank
      expect(board.tags).to eq([])
    end

    # The word list is immutable from here — fixing words is delete-and-rebuild.
    it "ignores anything other than description and tags" do
      board = built_board(name: "Built Board")
      build = create_build(board: board, status: "complete")

      patch admin_dashboard_board_build_path(build),
            params: { description: "New.", tags: "", name: "Hijacked", words: "nope | noun" }

      expect(build.reload.name).to eq("Playground")
      expect(board.reload.name).to eq("Built Board")
    end

    it "cannot reach a board this page didn't create" do
      other = Board.create!(name: "Someone Else's", slug: "someone-elses", user: seed_admin)
      build = create_build(board: other, status: "complete")

      patch admin_dashboard_board_build_path(build), params: { description: "Hijacked.", tags: "" }

      expect(other.reload.description).to be_blank
      expect(build.reload.description).to eq("Hijacked.")
    end
  end

  describe "GET duplicate" do
    before { sign_in admin }

    it "rehydrates the form from a stored plan, links and tile text intact" do
      build = create_build(
        topic: "the playground",
        audience: "an early communicator",
        description: "A playground board.",
        tags: %w[playground outdoor],
        plan: {
          "tiles" => [
            { "label" => "I", "part_of_speech" => "pronoun" },
            { "label" => "Food", "part_of_speech" => "noun", "display_label" => "Snacks", "links_to" => "food" },
          ],
          "children" => [
            { "key" => "food", "name" => "Food",
              "tiles" => [{ "label" => "back", "part_of_speech" => "social", "links_to" => "__root__" }] },
          ],
        },
      )

      get duplicate_admin_dashboard_board_build_path(build)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Food | noun | Snacks | &gt;food")
      expect(response.body).to include("back | social | &gt;__root__")
      expect(response.body).to include("the playground")
      expect(response.body).to include("an early communicator")
      expect(response.body).to include("A playground board.")
      expect(response.body).to include("playground, outdoor")
      expect(response.body).to include("children[0][key]")
    end

    it "writes nothing" do
      build = create_build

      expect { get duplicate_admin_dashboard_board_build_path(build) }
        .to not_change(AdminBoardBuild, :count).and not_change(Board, :count)
    end

    # Child pages inherit the root grid; copying a blank grid keeps it that way.
    it "leaves a child's grid blank" do
      build = create_build(
        plan: { "tiles" => [{ "label" => "I", "part_of_speech" => "pronoun" }],
                "children" => [{ "key" => "food", "name" => "Food",
                                 "tiles" => [{ "label" => "apple", "part_of_speech" => "noun" }] }] },
      )

      get duplicate_admin_dashboard_board_build_path(build)

      expect(response.body).to include('name="children[0][columns]" value=""')
    end

    it "redirects when the build is gone" do
      get duplicate_admin_dashboard_board_build_path(id: 0)

      expect(response).to redirect_to(admin_dashboard_board_builds_path)
    end
  end

  describe "POST preview duplicate-name warning" do
    before { sign_in admin }

    it "warns about an existing public board with the same name, ignoring case" do
      Board.create!(name: "playground", slug: "playground-public", user: seed_admin, predefined: true, published: true)

      post preview_admin_dashboard_board_builds_path, params: form_params(name: "Playground")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("already a board called")
    end

    # An unpublished board built here last week is exactly the collision worth
    # catching, and it isn't in public_boards yet.
    it "warns about an unpublished board this page built" do
      built_board(name: "Playground")

      post preview_admin_dashboard_board_builds_path, params: form_params(name: "Playground")

      expect(response.body).to include("already a board called")
    end

    it "says nothing when the name is free" do
      post preview_admin_dashboard_board_builds_path, params: form_params(name: "Something Else Entirely")

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("already a board called")
    end

    it "warns without blocking the build" do
      built_board(name: "Playground")

      expect { post admin_dashboard_board_builds_path, params: form_params(name: "Playground") }
        .to change(AdminBoardBuild, :count).by(1)
    end
  end

  describe "POST regenerate_art" do
    before do
      sign_in admin
      GenerateImagesJob.jobs.clear
    end

    def board_with_art_less_tile(board)
      image = Image.create!(label: "swing", user: seed_admin)
      board.add_image(image.id)
      image
    end

    it "queues generation for tiles with no picture" do
      board = built_board
      image = board_with_art_less_tile(board)
      build = create_build(board: board, status: "complete", topic: "the playground")

      post regenerate_art_admin_dashboard_board_build_path(build)

      expect(response).to redirect_to(admin_dashboard_board_build_path(build))
      expect(GenerateImagesJob.jobs.size).to eq(1)
      expect(GenerateImagesJob.jobs.first["args"].first).to include(image.id)
    end

    it "says so and queues nothing when every tile has a picture" do
      board = built_board
      build = create_build(board: board, status: "complete")

      post regenerate_art_admin_dashboard_board_build_path(build)

      expect(GenerateImagesJob.jobs).to be_empty
      expect(flash[:notice]).to match(/every tile/i)
    end

    it "cannot reach a board this page didn't create" do
      other = Board.create!(name: "Someone Else's", slug: "someone-elses-art", user: seed_admin)
      board_with_art_less_tile(other)
      build = create_build(board: other, status: "complete")

      post regenerate_art_admin_dashboard_board_build_path(build)

      expect(GenerateImagesJob.jobs).to be_empty
    end

    # Finding 2: the "missing art" count (used for display) includes images
    # that are already mid-flight from a prior GenerateImagesJob — but
    # queueing must not re-fire generation for one of those. Only a
    # genuinely-untouched image (no docs, not "generating") should be queued.
    it "does not re-queue an image that is already generating" do
      board = built_board
      generating_image = Image.create!(label: "swing", user: seed_admin, status: "generating")
      board.add_image(generating_image.id)
      untouched_image = board_with_art_less_tile(board)
      build = create_build(board: board, status: "complete", topic: "the playground")

      post regenerate_art_admin_dashboard_board_build_path(build)

      expect(GenerateImagesJob.jobs.size).to eq(1)
      queued_ids = GenerateImagesJob.jobs.first["args"].first
      expect(queued_ids).to include(untouched_image.id)
      expect(queued_ids).not_to include(generating_image.id)
    end
  end
end
