require 'rails_helper'

RSpec.describe "scenarios/index", type: :view do
  before(:each) do
    assign(:scenarios, [
      Scenario.create!(
        questions: "",
        answers: "",
        name: "Name",
        initial_description: "MyText",
        age_range: "Age Range"
      ),
      Scenario.create!(
        questions: "",
        answers: "",
        name: "Name",
        initial_description: "MyText",
        age_range: "Age Range"
      )
    ])
  end

  it "renders a list of scenarios" do
    render
    cell_selector = Rails::VERSION::STRING >= '7' ? 'div>p' : 'tr>td'
    assert_select cell_selector, text: Regexp.new("".to_s), count: 2
    assert_select cell_selector, text: Regexp.new("".to_s), count: 2
    assert_select cell_selector, text: Regexp.new("Name".to_s), count: 2
    assert_select cell_selector, text: Regexp.new("MyText".to_s), count: 2
    assert_select cell_selector, text: Regexp.new("Age Range".to_s), count: 2
  end
end
