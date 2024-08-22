require 'rails_helper'

RSpec.describe "scenarios/show", type: :view do
  before(:each) do
    assign(:scenario, Scenario.create!(
      questions: "",
      answers: "",
      name: "Name",
      initial_description: "MyText",
      age_range: "Age Range"
    ))
  end

  it "renders attributes in <p>" do
    render
    expect(rendered).to match(//)
    expect(rendered).to match(//)
    expect(rendered).to match(/Name/)
    expect(rendered).to match(/MyText/)
    expect(rendered).to match(/Age Range/)
  end
end
