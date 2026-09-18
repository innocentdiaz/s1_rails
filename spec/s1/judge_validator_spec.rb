# frozen_string_literal: true

RSpec.describe JudgeValidator do
  let(:asked) { [] }

  before do
    stub_s1 { |req| asked << [req.state, req.questions.values.first.instructions] and { noul: probability } }
  end

  context "when the model answers as expected" do
    let(:probability) { 0.85 }

    it "is valid" do
      expect(Reply.new(body: "My order arrived broken").errors).to be_empty
    end
  end

  context "when the question comes back false" do
    let(:probability) { 0.2 }

    it "adds the default error to the attribute" do
      reply = Reply.new(body: "asdf")
      expect(reply).not_to be_valid
      expect(reply.errors[:body]).to eq(["is invalid"])
    end

    it "measures the attribute alone when the model has no form" do
      Reply.new(body: "asdf").valid?
      expect(asked.first).to eq([{ body: "asdf" }, "Is `body` a coherent support request?"])
    end
  end

  context "with expect: false and a threshold" do
    let(:probability) { 0.75 }

    it "passes below the threshold and fails at it" do
      expect(Reply.new(body: "ok", note: "send it to my other email")).to be_valid
      stub_s1(noul: 0.8)
      reply = Reply.new(body: "ok", note: "send it to my other email")
      expect(reply).not_to be_valid
      expect(reply.errors[:note]).to eq(["is invalid"])
    end

    it "honours if:" do
      Reply.new(body: "ok").valid?
      expect(asked.map(&:last)).to eq(["Is `body` a coherent support request?"])
    end
  end

  it "requires a question" do
    expect { Class.new(Reply) { validates :body, judge: true } }.to raise_error(ArgumentError, /needs a question/)
    expect { Class.new(Reply) { validates :body, noul: true } }.to raise_error(ArgumentError, /needs a question/)
  end

  it "is reached by both spellings: judge: (the theory's) and noul: (the wire name)" do
    expect(NoulValidator).to be(described_class)
    expect(Reply.validators_on(:body).map(&:class)).to eq([described_class])
    klass = stub_const("Spelled", Class.new(Reply) { validates :note, judge: "Is `note` polite?" })
    expect(klass.validators_on(:note).map(&:class).uniq).to eq([described_class])
    expect(klass.validators_on(:note).map(&:kind).uniq).to eq([:judge])
  end

  it "judges a Measurable record as itself: its form under its declared lens, at the given threshold" do
    seen = nil
    stub_s1 { |req| seen = req.state and { noul: 0.7 } }
    klass = stub_const("Guarded", Class.new(Delivery) do
      measurable_as { { message: status } }
      measured_against { { policy: "same day" } }
      validates :status, judge: { with: "Is `this` within `policy`?", threshold: 0.6 }
    end)
    expect(klass.new(status: :attempted)).to be_valid
    expect(seen).to eq(this: { message: "attempted" }, policy: "same day")
    strict = stub_const("Stricter", Class.new(Delivery) { validates :status, noul: { with: "q?", threshold: 0.8 } })
    expect(strict.new(status: :attempted)).not_to be_valid
  end
end
