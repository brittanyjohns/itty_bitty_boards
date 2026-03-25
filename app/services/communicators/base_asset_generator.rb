# app/services/communicators/base_asset_generator.rb
require "open-uri"
require "base64"
require "tempfile"
require "rqrcode"

module Communicators
  class BaseAssetGenerator
    attr_reader :profile

    def initialize(profile)
      @profile = profile
    end

    private

    def rendered_html(template:, locals: {})
      ApplicationController.render(
        template: template,
        layout: "asset_export",
        assigns: locals,
      )
    end

    def qr_data_url_for(url, size: 400)
      return nil if url.blank?

      qr = RQRCode::QRCode.new(url)

      png = qr.as_png(
        size: size,
        border_modules: 4,
        module_px_size: 6,
      )

      encoded = Base64.strict_encode64(png.to_s)
      "data:image/png;base64,#{encoded}"
    end

    def logo_base64(path = Rails.root.join("public/logo_bubble.png"))
      return nil unless File.exist?(path)

      Base64.strict_encode64(File.binread(path))
    end

    def generate_png_from_html(html, width:, height:, scale: 2)
      grover = Grover.new(
        html,
        format: "png",
        viewport: { width: width, height: height },
        width: width,
        height: height,
        device_scale_factor: scale,
      )
      grover.to_png
    end

    def generate_pdf_from_html(html, width:, height:, scale: 2)
      grover = Grover.new(
        html,
        format: "A4",
        viewport: { width: width, height: height },
        print_background: true,
        prefer_css_page_size: true,
        scale: 1,
      )
      grover.to_pdf
    end

    def avatar_data_url
      avatar_url = profile.avatar_url
      return nil if avatar_url.blank?

      begin
        file = URI.open(avatar_url)
        content_type = file.content_type || "image/png"
        encoded = Base64.strict_encode64(file.read)
        "data:#{content_type};base64,#{encoded}"
      rescue => e
        Rails.logger.error("Failed to load avatar for asset generation: #{e.message}")
        nil
      end
    end

    def attach_binary(record:, attachment_name:, bytes:, filename:, content_type:, metadata: {})
      io = StringIO.new(bytes)
      record.public_send(attachment_name).attach(
        io: io,
        filename: filename,
        content_type: content_type,
        metadata: metadata,
      )
    end

    def attached_and_fresh?(attachment_name, signature:)
      attachment = profile.public_send(attachment_name)
      return false unless attachment.attached?

      attachment.metadata["signature"] == signature
    end
  end
end
