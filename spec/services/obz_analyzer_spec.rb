require "rails_helper"

RSpec.describe ObzAnalyzer do
  def analyze_fixture(name)
    described_class.analyze(File.binread(Rails.root.join("spec/data", name)))
  end

  describe ".analyze" do
    context "with an .obz package" do
      subject(:report) { analyze_fixture("simple.obz") }

      it "reports the obz format and finds the boards inside" do
        expect(report.dig(:package, :format)).to eq("obz")
        expect(report[:boards].size).to eq(1)
        expect(report.dig(:totals, :boards)).to eq(1)
      end

      it "counts the zip entries" do
        expect(report.dig(:package, :zip_entries)).to be > 0
        expect(report.dig(:package, :total_bytes)).to be > 0
      end

      it "carries no error" do
        expect(report[:error]).to be_nil
      end
    end

    # The bug this guards: a bare .obf isn't a zip, so the analyzer used to
    # raise, get swallowed, and return a zeroed-out report that the UI read
    # as "valid file, nothing in it".
    context "with a bare .obf document" do
      subject(:report) { analyze_fixture("test_internal.obf") }

      it "reports the obf format" do
        expect(report.dig(:package, :format)).to eq("obf")
        expect(report.dig(:package, :zip_entries)).to eq(0)
        expect(report.dig(:package, :total_bytes)).to be > 0
      end

      it "reports exactly one board with its real counts" do
        expect(report[:boards].size).to eq(1)
        expect(report.dig(:totals, :boards)).to eq(1)
        expect(report.dig(:totals, :buttons)).to eq(5)
        expect(report.dig(:totals, :images_defined)).to eq(5)
        expect(report.dig(:totals, :sounds_defined)).to eq(5)
      end

      it "describes the board itself, not a zip path" do
        board = report[:boards].first
        expect(board[:path]).to be_nil
        expect(board[:name]).to be_present
        expect(board.dig(:counts, :buttons)).to eq(5)
        expect(board.dig(:grid, :columns)).to eq(5)
      end

      it "resolves the single board as the root" do
        expect(report.dig(:root_board, :resolved)).to be true
        expect(report.dig(:root_board, :method)).to eq("single_obf")
      end

      it "reports no manifest without treating that as a failure" do
        expect(report.dig(:manifest, :found)).to be false
        expect(report.dig(:manifest, :total_boards_listed_or_found)).to eq(1)
        expect(report[:error]).to be_nil
      end

      it "counts inline image data when the file bundles it" do
        inline = analyze_fixture("lots_of_stuff.obf")
        expect(inline.dig(:package, :format)).to eq("obf")
        expect(inline.dig(:totals, :buttons)).to eq(5)
      end
    end

    context "with a file that is neither" do
      it "flags an unreadable file rather than reporting an empty package" do
        report = described_class.analyze("this is not a board")

        expect(report[:error]).to eq("unreadable_file")
        expect(report.dig(:package, :format)).to eq("unknown")
        expect(report[:boards]).to be_empty
      end

      it "does not leak the underlying exception to the caller" do
        report = described_class.analyze("this is not a board")
        expect(report[:warnings].join).not_to match(/Zip::Error|NoMethodError|backtrace/)
      end

      it "flags an empty JSON object as unreadable" do
        expect(described_class.analyze("{}")[:error]).to eq("unreadable_file")
      end

      it "flags a valid JSON array as unreadable" do
        expect(described_class.analyze("[1,2,3]")[:error]).to eq("unreadable_file")
      end
    end

    context "with a zip containing no boards" do
      it "reports no_boards_found" do
        buffer = Zip::OutputStream.write_buffer do |zos|
          zos.put_next_entry("readme.txt")
          zos.write("nothing to see here")
        end
        report = described_class.analyze(buffer.string)

        expect(report[:error]).to eq("no_boards_found")
        expect(report.dig(:package, :format)).to eq("obz")
      end
    end
  end

  describe ".count_boards" do
    it "counts a single bare .obf as one board" do
      bytes = File.binread(Rails.root.join("spec/data/test_internal.obf"))
      expect(described_class.count_boards(bytes)).to eq(1)
    end
  end
end
