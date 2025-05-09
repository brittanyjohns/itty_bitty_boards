require "obf"

def from_obf(path)
  puts "from obf"
  obf_json_or_path = path
  #   OBF::External.from_obf(path, "done.json")
  opts ||= {}
  obj = obf_json_or_path
  if obj.is_a?(String)
    obj = OBF::Utils.parse_obf(File.read(obf_json_or_path), opts)
  else
    obj = OBF::Utils.parse_obf(obf_json_or_path, opts)
  end
  (obj["buttons"] || []).each do |item|
    label = item["label"]
    if item["ext_saw_image_id"]
      image = Image.find_by(id: item["ext_saw_image_id"].to_i)
    else
      image = Image.find_or_create_by(label: label)
    end

    if item["path"]
      opts[type] ||= {}
      opts[type][item["path"]] ||= item
    end
  end

  obj["license"] = OBF::Utils.parse_license(obj["license"])
  obj
end

path_name = "obf_output_test.obf"

puts "Running test..."

from_obf(path_name)

puts "done."
