require "google_search_results"

params = {
  api_key: "84fd6df0a6cacdc1f996c076342cd0c797e140603583746faeffe4b1a5696968",
  engine: "google_images",
  google_domain: "google.com",
  q: "Coffee",
  hl: "en",
  gl: "us",
  safe: "active",
}

search = GoogleSearch.new(params)
hash_results = search.get_hash
