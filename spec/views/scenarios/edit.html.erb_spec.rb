require 'rails_helper'

RSpec.describe "scenarios/edit", type: :view do
  let(:scenario) {
    Scenario.create!(
      questions: "",
      answers: "",
      name: "MyString",
      initial_description: "MyText",
      age_range: "MyString"
    )
  }

  before(:each) do
    assign(:scenario, scenario)
  end

  it "renders the edit scenario form" do
    render

    assert_select "form[action=?][method=?]", scenario_path(scenario), "post" do

      assert_select "input[name=?]", "scenario[questions]"

      assert_select "input[name=?]", "scenario[answers]"

      assert_select "input[name=?]", "scenario[name]"

      assert_select "textarea[name=?]", "scenario[initial_description]"

      assert_select "input[name=?]", "scenario[age_range]"
    end
  end
end
