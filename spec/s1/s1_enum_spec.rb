# frozen_string_literal: true

RSpec.describe "s1_enum" do
  it "declares a string-backed enum and keeps the descriptions" do
    expect(Delivery.statuses).to eq("delivered" => "delivered", "attempted" => "attempted", "undeliverable" => "undeliverable")
    expect(Delivery.s1_enum(:status)).to eq(delivered: "Handed over or left somewhere", attempted: "Tried, no one there",
                                            undeliverable: "Bad address")
    expect(Delivery.new(status: :attempted)).to be_attempted
  end

  it "passes values: and enum options through" do
    expect(Delivery.priorities).to eq("low" => 0, "high" => 1)
    expect(Delivery.new(priority: :high)).to be_priority_high
  end

  it "is also measured_enum and choice_enum" do
    expect(Delivery.method(:measured_enum)).to eq(Delivery.method(:s1_enum))
    expect(Delivery.method(:choice_enum)).to eq(Delivery.method(:s1_enum))
  end

  it "raises for an undeclared name" do
    expect { Delivery.s1_enum(:colour) }.to raise_error(ArgumentError, /no choice_enum :colour/)
  end

  describe "choice questions" do
    let(:delivery) { Delivery.create!(status: :attempted) }
    let(:asked) { [] }

    before { stub_s1 { |req| asked << req.questions and { status: :delivered, outcome: :delivered, choice: :delivered, note: :bulky } } }

    it "fills categories from the s1_enum named after the id" do
      delivery.as(:sms, body: "left it with the neighbour").update_measure { |q| q.choose :status, "What is the sender reporting?" }
      expect(asked.last[:status].criteria).to eq("delivered" => "Handed over or left somewhere", "attempted" => "Tried, no one there",
                                                 "undeliverable" => "Bad address")
      expect(delivery.reload).to be_delivered
    end

    it "asks the enum's own question when none is given" do
      delivery.update_measure { |q| q.choose :status }
      expect(asked.last[:status].instructions).to eq("What is the sender reporting?")
      expect(delivery.reload).to be_delivered
    end

    it "takes s1_enum names in place of a block" do
      delivery.update_measure(:status, as: :sms, body: "left it")
      expect(asked.last.keys).to eq([:status])
      delivery.as(:sms, body: "x").measure(%i[status])
      expect(asked.last[:status].criteria.keys).to eq(%w[delivered attempted undeliverable])
    end

    it "raises when there is no question to use" do
      expect { delivery.measure { |q| q.choose :priority } }.to raise_error(ArgumentError, /no declared question for :priority/)
      expect { delivery.measure { |q| q.choose :note } }.to raise_error(ArgumentError, /no declared question for :note/)
    end

    it "takes enum: explicitly, on batches and single questions" do
      delivery.measure { |q| q.choose :outcome, "Outcome?", enum: :status }
      expect(asked.last[:outcome].criteria.keys).to eq(%w[delivered attempted undeliverable])
      expect(delivery.choice("Outcome?", enum: :status)).to eq(:delivered)
      expect(delivery.choose("Outcome?", enum: :status).to_sym).to eq(:delivered)
      expect(delivery.measure { |q| q.choose :outcome, enum: :status }[:outcome].to_sym).to eq(:delivered)
    end

    it "falls back to a plain enum's keys" do
      delivery.measure { |q| q.choose :note, "Handling?" }
      expect(asked.last[:note].criteria).to eq("fragile" => nil, "bulky" => nil)
    end

    it "raises when enum: names nothing, and still needs categories otherwise" do
      expect { delivery.measure { |q| q.choose :x, "?", enum: :colour } }.to raise_error(ArgumentError, /no s1_enum or enum :colour/)
      expect { delivery.measure { |q| q.choose :colour, "?" } }.to raise_error(S1::ValidationError, /at least 2 options/)
    end

    it "serializes through update_measure_later" do
      delivery.update_measure_later(as: :sms, body: "nobody home") { |q| q.choose :status, "Reporting?" }
      perform_enqueued_jobs
      expect(asked.last[:status].criteria.keys).to eq(%w[delivered attempted undeliverable])
    end
  end
end
