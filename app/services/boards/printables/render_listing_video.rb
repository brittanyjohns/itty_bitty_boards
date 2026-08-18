# The marketplace listing video: a flip-through of the printed pages.
#
# Etsy gives every listing one video slot, above the fold on mobile, and ours
# was empty. What goes in it is the one thing the still gallery can't show —
# that this is a BUNDLE of linked pages that turn, with the back buttons landing
# where they should, so a printed set navigates the way the app does. The pages
# are cut through in tree order, root first, and the clip lands on the QR.
#
# Frames are Grover-rendered square cards, not raw page images stitched by an
# ffmpeg filter graph. Three reasons, in order of weight:
#
#   1. RenderPageThumbnails already hands back data URIs, which is exactly what
#      an <img src> in a template wants. The filter route means decoding them
#      back to bytes to feed a graph that then has to pad and centre each one at
#      dimensions that vary per page (trim_trailing_blank crops each to its own
#      height).
#   2. Every brand element — the palette, the inlined fonts, the ribbon, the
#      badge, the QR — is already CSS in layouts/listing_image.html.erb.
#      ffmpeg's drawtext can reproduce none of it.
#   3. A page is Letter-shaped on a square canvas. Letterboxing is one CSS rule
#      and a runtime-built filter graph otherwise.
#
# Etsy STRIPS the audio from a listing video, so the clip has to carry
# everything it says visually. Nothing here encodes an audio stream.
#
# Grover plus ffmpeg, so it belongs on Sidekiq and never on a request thread.
module Boards
  module Printables
    class RenderListingVideo
      # Square, matching the gallery slides, and 1080 is Etsy's recommended
      # size. Rendered at device_scale_factor 1 rather than the slides' 2: the
      # output really is 1080 square, so a 2160px frame is only downscaled by
      # ffmpeg. As on the slides, the scale must sit INSIDE `viewport` — Grover
      # silently ignores it anywhere else.
      FRAME_PX = 1080

      # Same cap as ContentTilePlan::MAX_TILES, deliberately: the video and the
      # what's-included grid should agree on how many pages a buyer is shown.
      MAX_PAGE_FRAMES = 8

      # The outro holds the QR, which a buyer may actually be pointing a phone
      # at, so it gets the longest dwell.
      INTRO_SECONDS = 1.6
      OUTRO_SECONDS = 2.6

      # Page holds shrink as the set grows, within bounds that keep a 1-page
      # printable above Etsy's 5s floor and a 25-page one under its 15s ceiling.
      # #plan_seconds is exhaustively specced over 1..25 rather than trusted.
      PAGE_SECONDS_BUDGET = 6.0
      MIN_PAGE_SECONDS = 0.9
      MAX_PAGE_SECONDS = 1.6

      # A hard ffmpeg-side ceiling under Etsy's 15s, so a miscomputed plan
      # produces a short video rather than a rejected one.
      ENCODE_CEILING_SECONDS = 14.5

      Frame = Struct.new(:png, :seconds, keyword_init: true)

      def initialize(printable:)
        @printable = printable
      end

      # => the attached blob, or nil when nothing could be produced.
      def call
        # FIRST, before any rendering. Discovering the binaries are missing
        # after ten Grover frames throws away minutes of headless Chrome, and
        # ProcessTileVideoJob sets the same precedent.
        unless VideoTranscoder.available?
          Rails.logger.warn("[RenderListingVideo] printable=#{printable.id} skipped: ffmpeg unavailable")
          return nil
        end

        frames = build_frames
        if frames.size < 2
          Rails.logger.warn("[RenderListingVideo] printable=#{printable.id} skipped: no pages rendered")
          return nil
        end

        encode(frames)
      end

      # The clip's length, as a pure function of how many page frames it holds.
      # Separated from everything that touches Grover or the filesystem so the
      # duration contract can be tested across every board count we allow.
      def self.plan_seconds(page_frames)
        pages = page_frames.clamp(0, MAX_PAGE_FRAMES)
        INTRO_SECONDS + OUTRO_SECONDS + (pages * page_seconds(pages))
      end

      def self.page_seconds(pages)
        return 0.0 if pages.zero?

        (PAGE_SECONDS_BUDGET / pages).clamp(MIN_PAGE_SECONDS, MAX_PAGE_SECONDS)
      end

      private

      attr_reader :printable

      def board = printable.board

      def board_count = [printable.board_ids.to_a.size, 1].max

      # Colour, page header SHOWN — the same pass the hero uses. The printed QR
      # lives in that header, and the flip-book pitch is that the sheet itself
      # carries the code.
      def thumbnails
        @thumbnails ||= RenderPageThumbnails.new(
          boards: printable.ordered_boards.first(MAX_PAGE_FRAMES),
        ).call
      end

      # Tree order, root first, minus any board whose page render failed — the
      # same rule the slides use. A missing page costs a frame, not the video.
      def pages
        @pages ||= printable.ordered_boards.first(MAX_PAGE_FRAMES).filter_map do |page|
          thumbnail = thumbnails[page.id]
          next unless thumbnail

          {board: page, thumbnail: thumbnail}
        end
      end

      # Rendered in playback order, deliberately: building the page frames
      # first and splicing the intro in front leaves render order and frame
      # order disagreeing, which is invisible in the output and confusing in
      # every log line and spec that watches the renders go past.
      def build_frames
        return [] if pages.empty?

        hold = self.class.page_seconds(pages.size)
        frames = [Frame.new(png: render("intro", assigns: intro_assigns), seconds: INTRO_SECONDS)]

        pages.each_with_index do |page, index|
          frames << Frame.new(png: render("page", assigns: page_assigns(page, index)), seconds: hold)
        end

        frames << Frame.new(png: render("outro", assigns: outro_assigns), seconds: OUTRO_SECONDS)
      end

      # ffmpeg needs real paths, so the frames land in a temp dir. Block form,
      # so a raise part-way through still cleans up.
      def encode(frames)
        Dir.mktmpdir("listing-video") do |dir|
          entries = frames.each_with_index.map do |frame, index|
            path = File.join(dir, format("frame-%03d.png", index))
            File.binwrite(path, frame.png)
            [path, frame.seconds]
          end

          output = File.join(dir, "listing.mp4")
          return nil unless VideoTranscoder.encode_still_sequence(
            entries, output, max_seconds: ENCODE_CEILING_SECONDS,
          )

          attach(output)
        end
      end

      # The duration is measured off the encoded file rather than trusted from
      # the plan. A clip outside Etsy's window is refused here, where it can be
      # logged, rather than at listing-activation time in the seller UI where
      # the reason is a long way from the cause.
      def attach(path)
        duration = VideoTranscoder.duration(path)
        if duration.nil? ||
           duration < BoardPrintable::VIDEO_MIN_SECONDS ||
           duration > BoardPrintable::VIDEO_MAX_SECONDS
          Rails.logger.warn(
            "[RenderListingVideo] printable=#{printable.id} discarded: #{duration.inspect}s is outside " \
            "#{BoardPrintable::VIDEO_MIN_SECONDS}-#{BoardPrintable::VIDEO_MAX_SECONDS}s",
          )
          return nil
        end

        printable.attach_video!(bytes: File.binread(path), duration: duration)
      end

      def shared_assigns
        {
          logo: BrandAssets.logo_data_uri,
          palette_css: Palette.for(board).css_vars,
          title: Boards::AssetRendering.board_title_for(board),
        }
      end

      def intro_assigns
        shared_assigns.merge(
          background: BrandAssets.scene_data_uri_for(board),
          headline: ::Printables::SlideCopy.video_intro_headline(board_count: board_count),
          count_badge: ::Printables::SlideCopy.hero_count_badge(board_count: board_count),
        )
      end

      def page_assigns(page, index)
        shared_assigns.merge(
          thumbnail: page[:thumbnail],
          page_label: Boards::AssetRendering.board_title_for(page[:board]),
          position: index + 1,
          total: pages.size,
          # Every page after the first is one a buyer reached by following a
          # folder tile, and every one of those carries a way back. That marker
          # is the whole linked-navigation claim, and it costs one span.
          back_marker: index.positive? ? ::Printables::SlideCopy.video_back_marker : nil,
        )
      end

      def outro_assigns
        shared_assigns.merge(
          qr_data_url: Qr.data_url_for(
            Qr.listing_target_url_for(board, content: "listing_video"),
            level: Qr::SCREEN_ECC,
          ),
          headline: ::Printables::SlideCopy.video_outro_headline,
          sub_lines: ::Printables::SlideCopy.video_outro_sub_lines,
          device_data_uri: device_data_uri,
        )
      end

      # The root board in app chrome, reusing the slide gallery's shell. Fails
      # soft: the outro still carries the QR and the copy without it.
      def device_data_uri
        root = pages.find { |page| page[:board].id == board.id } || pages.first
        return nil unless root

        RenderDeviceScreen.new(title: shared_assigns[:title], thumbnail: root[:thumbnail]).call
      rescue StandardError => e
        Rails.logger.warn("[RenderListingVideo] device screen skipped: #{e.class}: #{e.message}")
        nil
      end

      def render(template, assigns:)
        html = ApplicationController.render(
          template: "api/board_printables/video/#{template}",
          layout: "listing_image",
          assigns: assigns,
          formats: [:html],
        )

        Grover.new(
          html,
          viewport: {width: FRAME_PX, height: FRAME_PX, device_scale_factor: 1},
          print_background: true,
        ).to_png
      end
    end
  end
end
