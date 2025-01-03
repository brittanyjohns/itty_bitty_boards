require "rails_helper"
RSpec.describe ImportFromObfJob, type: :job do
  describe "#perform" do
    obf_zip_file_path = Rails.root.join("spec", "data", "path_images.obz")
    obf_zip_file = File.open(obf_zip_file_path)
    extracted_data = OBF::OBZ.to_external(obf_zip_file, {})
    file_name = obf_zip_file.ba
    @root_board_id = nil
    Zip::File.open(obf_zip_file.path) do |zip_file|
      zip_file.each do |entry|
        puts "Entry: #{entry.name}"
        if entry.name == "manifest.json"
          manifest = JSON.parse(entry.get_input_stream.read)
          puts "Manifest: #{manifest}"
          @root_board_id = manifest["root"]
        end
      end
    end
    it "imports from OBZ file" do
      json_data = {
        extracted_obz_data: extracted_data,
        current_user_id: 1,
        group_name: file_name,
        root_board_id: 1,
      }.to_json
      ImportFromObfJob.new.perform(json_data)
    end
  end
end
