require 'rails_helper'

RSpec.describe "scenarios/new", type: :view do
  before(:each) do
    assign(:scenario, Scenario.new(
      questions: "",
      answers: "",
      name: "MyString",
      initial_description: "MyText",
      age_range: "MyString"
    ))
  end

  it "renders new scenario form" do
    render

    assert_select "form[action=?][method=?]", scenarios_path, "post" do

      assert_select "input[name=?]", "scenario[questions]"

      assert_select "input[name=?]", "scenario[answers]"

      assert_select "input[name=?]", "scenario[name]"

      assert_select "textarea[name=?]", "scenario[initial_description]"

      assert_select "input[name=?]", "scenario[age_range]"
    end
  end
end
