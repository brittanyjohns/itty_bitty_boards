require "rbconfig"

Grover.configure do |config|
  config.options = {
    format: "Letter",
    prefer_css_page_size: true,
    print_background: true,
    margin: { top: "12mm", right: "12mm", bottom: "14mm", left: "12mm" },
    wait_until: "networkidle0",
    # If your host needs it, keep --no-sandbox; add --disable-dev-shm-usage for low-memory boxes
    launch_args: ["--no-sandbox", "--disable-dev-shm-usage"],
  }
end
