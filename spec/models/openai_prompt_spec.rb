require "rails_helper"

RSpec.describe OpenaiPrompt, type: :model do
  describe "#transform_into_json" do
    it "correctly transforms multiple JSON objects into a JSON array" do
      input_str = <<~JSON
        {
          "scenario": "Going to school",
          "description": "Walking to the bus stop, waiting for the bus, getting on the bus, finding a seat, waving to parents, saying hello to the bus driver, looking out the window, talking quietly with friends, listening to announcements, arriving at school, getting off the bus, walking to the school entrance"
        }
        {
          "scenario": "Riding the bus",
          "description": "Sitting on the bus seat, buckling seatbelt if available, looking out the window, waving at passing cars, playing with a toy or book, talking to the bus driver or bus monitor, asking to stop for restroom break, pointing out things outside the bus, listening to announcements or music played on the bus"
        }
      JSON

      expected_output = [
        {
          "scenario" => "Going to school",
          "description" => "Walking to the bus stop, waiting for the bus, getting on the bus, finding a seat, waving to parents, saying hello to the bus driver, looking out the window, talking quietly with friends, listening to announcements, arriving at school, getting off the bus, walking to the school entrance",
        },
        {
          "scenario" => "Riding the bus",
          "description" => "Sitting on the bus seat, buckling seatbelt if available, looking out the window, waving at passing cars, playing with a toy or book, talking to the bus driver or bus monitor, asking to stop for restroom break, pointing out things outside the bus, listening to announcements or music played on the bus",
        },
      ]

      openai_prompt = OpenaiPrompt.new
      output = openai_prompt.transform_into_json(input_str)
      puts "Transformed JSON: #{output}\n\n\n"
      expect(output).not_to be_nil
      expect(JSON.parse(output)).to eq(expected_output)
    end

    it "returns nil if the input string is not valid JSON" do
      invalid_input_str = "invalid json string"

      openai_prompt = OpenaiPrompt.new
      output = openai_prompt.transform_into_json(invalid_input_str)
      expect(output).to be_nil
    end
  end

  describe "#set_scenario_description" do
    let(:openai_prompt) { OpenaiPrompt.create(prompt_text: "Going to school", age_range: "4-6") }
    let(:mock_response) do
      {
        content: <<~JSON,
          {
            "scenario": "Going to school",
            "description": "Walking to the bus stop, waiting for the bus, getting on the bus, finding a seat, waving to parents, saying hello to the bus driver, looking out the window, talking quietly with friends, listening to announcements, arriving at school, getting off the bus, walking to the school entrance"
          }
          {
            "scenario": "Riding the bus",
            "description": "Sitting on the bus seat, buckling seatbelt if available, looking out the window, waving at passing cars, playing with a toy or book, talking to the bus driver or bus monitor, asking to stop for restroom break, pointing out things outside the bus, listening to announcements or music played on the bus"
          }
        JSON
      }
    end

    before do
      allow(OpenAiClient).to receive(:new).and_return(double(create_chat: mock_response))
      allow(openai_prompt).to receive(:transform_into_json).and_call_original
      allow(openai_prompt).to receive(:valid_json?).and_return(false)
    end

    it "sets the description correctly after transforming the JSON response" do
      openai_prompt.set_scenario_description
      expect(openai_prompt.description).to eq(
        "Walking to the bus stop, waiting for the bus, getting on the bus, finding a seat, waving to parents, saying hello to the bus driver, looking out the window, talking quietly with friends, listening to announcements, arriving at school, getting off the bus, walking to the school entrance\n" +
        "Sitting on the bus seat, buckling seatbelt if available, looking out the window, waving at passing cars, playing with a toy or book, talking to the bus driver or bus monitor, asking to stop for restroom break, pointing out things outside the bus, listening to announcements or music played on the bus"
      )
    end

    it "logs an error if the JSON is invalid" do
      allow(openai_prompt).to receive(:transform_into_json).and_return(nil)
      expect(Rails.logger).to receive(:error).with(/Did not receive valid response/)
      openai_prompt.set_scenario_description
    end
  end
end
