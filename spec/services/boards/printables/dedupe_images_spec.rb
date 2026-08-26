require "rails_helper"

# Every fixture here is a real, minimal PDF built by hand, so the service sees
# the same reference-hash graph CombinePDF hands it after parsing a Grover
# render.
#
# The assertions are about the OBJECT GRAPH, not the file size, and that is
# deliberate. CombinePDF collapses objects its own `==` calls equal when it
# assigns object ids, and a fixture simple enough to write by hand is simple
# enough for it to catch — so a byte-size assertion here would pass whether or
# not this service did anything. What produces the saving on real output is
# exactly the property below: pages holding the same picture end up pointing at
# one object. Size is proven against real Grover pages instead — see
# `.claude-notes/board-printables-etsy.md`.
RSpec.describe Boards::Printables::DedupeImages do
  # One page, one image XObject, optionally with an alpha channel. The mask's
  # object NUMBER varies because separately-rendered pages number their objects
  # independently, which is the whole reason the duplicates survive the merge.
  def image_page_pdf(pixels, alpha: nil, alpha_object: 6)
    side = Integer(Math.sqrt(pixels.bytesize))
    data = Zlib::Deflate.deflate(pixels)
    content = "q 100 0 0 100 10 10 cm /Im0 Do Q"
    smask = alpha ? " /SMask #{alpha_object} 0 R" : ""

    body = +"%PDF-1.4\n"
    add = ->(number, object) { body << "#{number} 0 obj\n#{object}\nendobj\n" }
    add.call(1, "<< /Type /Catalog /Pages 2 0 R >>")
    add.call(2, "<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
    add.call(3, "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] " \
                "/Resources << /XObject << /Im0 5 0 R >> >> /Contents 4 0 R >>")
    add.call(4, "<< /Length #{content.bytesize} >>\nstream\n#{content}\nendstream")
    add.call(5, "<< /Type /XObject /Subtype /Image /Width #{side} /Height #{side} " \
                "/ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode#{smask} " \
                "/Length #{data.bytesize} >>\nstream\n#{data}\nendstream")
    if alpha
      mask = Zlib::Deflate.deflate(alpha)
      add.call(alpha_object, "<< /Type /XObject /Subtype /Image /Width #{side} /Height #{side} " \
                             "/ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode " \
                             "/Length #{mask.bytesize} >>\nstream\n#{mask}\nendstream")
    end
    body << "trailer\n<< /Size 40 /Root 1 0 R >>\nstartxref\n0\n%%EOF\n"
    body
  end

  def deref(object)
    object.is_a?(Hash) ? (object[:referenced_object] || object) : object
  end

  # The image each page actually draws, after following the reference.
  def images_on_pages(pdf)
    pdf.pages.map do |page|
      xobjects = deref(deref(page[:Resources])[:XObject])
      deref(xobjects[:Im0])
    end
  end

  def document(*pages)
    pages.each_with_object(CombinePDF.new) { |bytes, pdf| pdf << CombinePDF.parse(bytes) }
  end

  let(:apple) { ("\x11" * 4096).b }
  let(:banana) { ("\x99" * 4096).b }
  let(:opaque) { ("\xFF" * 4096).b }
  let(:faded) { ("\x40" * 4096).b }

  it "points pages holding the same picture at one image" do
    pdf = document(
      image_page_pdf(apple, alpha: opaque, alpha_object: 6),
      image_page_pdf(apple, alpha: opaque, alpha_object: 9),
    )

    described_class.new(pdf).call
    first, second = images_on_pages(pdf)

    expect(first).to be(second)
  end

  it "leaves a different picture alone" do
    pdf = document(
      image_page_pdf(apple, alpha: opaque),
      image_page_pdf(banana, alpha: opaque),
    )

    described_class.new(pdf).call
    first, second = images_on_pages(pdf)

    expect(first).not_to be(second)
  end

  # The trap this service could most easily fall into. Tile art is transparent
  # PNG, so two tiles can carry identical colour data and different alpha —
  # fingerprinting the image stream alone would print the wrong one.
  it "keeps two pictures apart when only their alpha differs" do
    pdf = document(
      image_page_pdf(apple, alpha: opaque),
      image_page_pdf(apple, alpha: faded),
    )

    result = described_class.new(pdf).call
    first, second = images_on_pages(pdf)

    expect(first).not_to be(second)
    expect(result.unique).to eq(2)
  end

  it "keeps every page, in order, at its own size" do
    pdf = document(
      image_page_pdf(apple, alpha: opaque),
      image_page_pdf(apple, alpha: opaque, alpha_object: 9),
      image_page_pdf(banana, alpha: opaque),
    )
    before = pdf.pages.map { |page| page[:MediaBox] }

    described_class.new(pdf).call

    expect(pdf.pages.map { |page| page[:MediaBox] }).to eq(before)
    expect(pdf.pages.length).to eq(3)
  end

  it "counts only the entries it actually rewrote" do
    pdf = document(
      image_page_pdf(apple, alpha: opaque),
      image_page_pdf(apple, alpha: opaque, alpha_object: 9),
      image_page_pdf(banana, alpha: opaque),
    )

    result = described_class.new(pdf).call

    expect(result).to have_attributes(deduped: 1, unique: 2)
  end

  it "does nothing to a document with no images" do
    pdf = CombinePDF.new
    pdf << CombinePDF.create_page([0, 0, 612, 792])

    expect { described_class.new(pdf).call }.not_to raise_error
    expect(described_class.new(pdf).call).to have_attributes(deduped: 0, unique: 0)
  end
end
