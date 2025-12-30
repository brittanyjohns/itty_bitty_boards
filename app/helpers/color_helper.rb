module ColorHelper
  HEX = {
    # Presets (your current palette)
    "white" => "#FFFFFF",
    "red" => "#FF0000",
    "red pink" => "#FF709C",
    "pinky purple" => "#FF73DE",
    "light red-orange" => "#FAC48C",
    "orange" => "#FFC457",
    "yellow" => "#FFEA75",
    "yellowy" => "#FFF15C",
    "light yellow" => "#FCF286",
    "dark green" => "#52D156",
    "navy green" => "#95BD2A",
    "green" => "#A1F571",
    "pale green" => "#C4FC8D",
    "strong blue" => "#5ECFFF",
    "happy blue" => "#94DFFF",
    "bluey" => "#B0DFFF",
    "light blue" => "#C2F1FF",
    "dark purple" => "#7698C7",
    "light purple" => "#D0BEE8",
    "brown" => "#994F00",
    "dark blue" => "#006DEB",
    "black" => "#000000",
    "gray" => "#A1A1A1",
    "dark orange" => "#FF6C3B",

    # Legacy "parts of speech" names you currently use
    "blue" => "#006DEB",
    "teal" => "#2ABED1",
    "pink" => "#FF709C",
    "purple" => "#7645EF",
  }.freeze

  module_function

  def to_hex(value, default: "#FFFFFF")
    return default if value.blank?

    val = value.to_s.strip

    # already hex
    if val.match?(/\A#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})\z/)
      return expand_short_hex(val).upcase
    end

    # rgb(r,g,b)
    if (hex = rgb_string_to_hex(val))
      return hex
    end

    # tailwind-ish class e.g. "bg-blue-400"
    if val.start_with?("bg-")
      name = val.split("-")[1] # "blue"
      return HEX[name] if HEX[name].present?
    end

    # word/preset
    HEX[val.downcase] || default
  end

  def expand_short_hex(hex)
    return hex if hex.length == 7
    "##{hex[1]}#{hex[1]}#{hex[2]}#{hex[2]}#{hex[3]}#{hex[3]}"
  end

  def rgb_string_to_hex(str)
    m = str.match(/\Argb\(\s*(\d{1,3})\s*,\s*(\d{1,3})\s*,\s*(\d{1,3})\s*\)\z/i)
    return nil unless m
    r = m[1].to_i.clamp(0, 255)
    g = m[2].to_i.clamp(0, 255)
    b = m[3].to_i.clamp(0, 255)
    format("#%02X%02X%02X", r, g, b)
  end

  # Contrast-safe text color
  # Prefers black text unless background is very dark
  def text_hex_for(bg_value, light: "#FFFFFF", dark: "#000000")
    hex = to_hex(bg_value, default: "#FFFFFF")

    r = hex[1..2].to_i(16)
    g = hex[3..4].to_i(16)
    b = hex[5..6].to_i(16)

    brightness = (r * 299 + g * 587 + b * 114) / 1000.0

    # Only use white text for very dark backgrounds
    brightness < 90 ? light : dark
  end
end
