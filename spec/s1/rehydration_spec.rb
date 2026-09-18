# frozen_string_literal: true

require "rake"

# s1_answers as a source, not an audit: measurement(:col) rebuilds the distribution over the
# scale, threshold and confidence it was taken with; the stored question_digest tells a row
# measured under another question — Model.stale(:col), record.stale?(:col), rake s1:remeasure.
RSpec.describe "rehydration" do
  let(:ticket) { Ticket.create!(body: "I have asked three times. Can I talk to a real person?", plan: "gold") }
  let(:requests) { [] }

  before { stub_s1 { |req| requests << req and { escalate: 0.75, department: :billing, severity: 1, subtype: :missing, quality: 2 } } }

  describe "the audit entry" do
    it "keeps the kind, the collapse, the scale, the threshold, the confidence, the question's digest, and who answered when" do
      ticket.update_measure(:escalate, :department, :severity)
      ticket.reload
      escalate, department, severity = ticket.s1_answers.values_at("escalate", "department", "severity")
      expect(escalate.keys).to eq(%w[kind value probabilities scale threshold question_digest form provider model measured_at])
      expect(severity.keys).to eq(%w[kind value position probabilities confidence scale question_digest form provider model measured_at])
      expect(escalate).to include("kind" => "noul", "value" => "true", "threshold" => 0.7, "scale" => %w[true false],
                                  "form" => "default", "provider" => "stub", "model" => "stub")
      expect(escalate["probabilities"]).to eq("true" => 0.75, "false" => 0.25)
      expect(Time.iso8601(escalate["measured_at"])).to be_within(5).of(Time.now)
      expect(escalate["question_digest"]).to match(/\A\h{64}\z/)
      expect(escalate["question_digest"]).to eq(Ticket.s1_question_digest(:escalate))
      expect(department).to include("kind" => "choice", "value" => "billing", "scale" => %w[returns billing], "confidence" => 1.0, "form" => "planned")
      expect(severity).to include("kind" => "score", "value" => "degraded", "position" => 1, "scale" => %w[cosmetic degraded blocking],
                                  "confidence" => 1.0)
      expect(severity["question_digest"]).to eq(Ticket.s1_question_digest(:severity))
      expect(severity).not_to have_key("threshold")
    end

    it "digests the question as asked — other wording, or inline criteria, is another question" do
      ticket.update_measure { |q| q.judge :escalate, "Other wording?" }
      expect(ticket.reload.s1_answers.dig("escalate", "question_digest")).not_to eq(Ticket.s1_question_digest(:escalate))
      expect(ticket).to be_stale(:escalate)
      ticket.update_measure(:escalate)
      expect(ticket.reload).not_to be_stale(:escalate)
      ticket.update_measure(:escalate, given: { extra: 1 }) # the lens is the state's, not the question's
      expect(ticket.reload).not_to be_stale(:escalate)
    end

    it "keeps a block question's scale and digest too — the question as asked" do
      call = PhoneCall.create!(firm: Firm.create!(name: "f"), transcript: "x")
      call.update_measure { |q| q.score :quality, "Quality?", "D", "C", "B", "A" }
      expect(call.reload.s1_answers.fetch("quality")).to include("kind" => "score", "value" => "B", "scale" => %w[D C B A])
      expect(call.s1_answers.dig("quality", "question_digest"))
        .to eq(S1::Measurable::Declarations.digest(S1::Question::Score.new(instructions: "Quality?", criteria: %w[D C B A])))
      expect(call.measurement(:quality).level).to eq("B")
    end
  end

  describe "measurement" do
    it "rebuilds each kind over the stored scale, at the stored threshold, with the stored confidence" do
      ticket.update_measure(:escalate, :department, :severity)
      ticket.reload
      noul = ticket.measurement(:escalate)
      expect(noul).to be_a(S1::Answer::Noul)
      expect(noul.to_f).to eq(0.75)
      expect(noul.threshold).to eq(0.7)
      expect(noul.true?).to be(true)
      expect(noul.true?(0.9)).to be(false)
      expect(noul.probabilities).to eq("true" => 0.75, "false" => 0.25)
      choice = ticket.measurement(:department)
      expect(choice.to_sym).to eq(:billing)
      expect(choice.categories).to eq(%i[returns billing])
      expect(choice.confidence).to eq(1.0)
      score = ticket.measurement(:severity)
      expect(score.level).to eq("degraded")
      expect(score.levels.map(&:to_s)).to eq(%w[cosmetic degraded blocking])
      expect(score.expectation).to eq(1.0)
      expect(score.confidence).to eq(1.0)
      expect(ticket.measurement(:priority)).to be_nil
    end

    it "reads the threshold and the scale the row was measured with, not the declaration's now" do
      ticket.as(threshold: 0.9).update_measure(%i[escalate severity])
      ticket.reload
      expect(ticket.escalate).to be(false)
      expect(ticket.measurement(:escalate).threshold).to eq(0.9)
      expect(ticket.measurement(:escalate).true?).to be(false)
      later = Class.new(Ticket) do
        judges :escalate, "q", threshold: 0.5
        scores :severity, "q", :low, :mid, :high
      end
      row = later.find(ticket.id)
      expect(row.measurement(:escalate).threshold).to eq(0.9)
      expect(row.measurement(:severity).level).to eq("degraded")
      expect(row.measurement(:severity).levels.map(&:to_s)).to eq(%w[cosmetic degraded blocking])
    end
  end

  describe "Model.stale(:col)" do
    it "is the rows never measured, or measured under another question — in SQL where the adapter reads JSON" do
      ticket
      other = Ticket.create!(body: "y")
      expect(Ticket.stale(:escalate)).to contain_exactly(ticket, other)
      expect(Ticket.stale(:escalate).to_sql).to include("json_extract").and include("$.escalate.question_digest")
      ticket.update_measure(:escalate)
      expect(Ticket.stale(:escalate)).to eq([other])
      expect(Ticket.stale(:escalate).where(id: ticket.id)).to be_empty
      expect(Ticket.where(id: ticket.id).stale(:escalate)).to be_empty
      reworded = Class.new(Ticket) { judges :escalate, "Is the customer asking to speak to a person?", threshold: 0.7 }
      expect(reworded.stale(:escalate).ids).to contain_exactly(ticket.id, other.id)
      expect(reworded.find(ticket.id)).to be_stale(:escalate)
      recriteria = Class.new(Ticket) { judges :escalate, "Is the customer asking for a human agent?", true: "asks for a person" }
      expect(recriteria.stale(:escalate).ids).to contain_exactly(ticket.id, other.id)
      same = Class.new(Ticket) do
        judges :escalate, "Is the customer asking for a human agent?", true: ["asks for a person", "threatens to leave"], false: "a routine request"
      end
      expect(same.stale(:escalate).ids).to eq([other.id]) # the threshold is the collapse's, not the question's
      expect { Ticket.stale(:plan) }.to raise_error(ArgumentError, /:plan is not a measured field/)
      expect { Delivery.stale(:status) }.to raise_error(ArgumentError, /stale needs an s1_answers column/)
    end

    it "falls back to Ruby for a dynamic scale, whose question is per record" do
      stub_s1 { |req| { subtype: req.questions[:subtype].categories.first } }
      ticket.update!(department: "billing")
      other = Ticket.create!(body: "y", department: "returns")
      ticket.update_measure(:subtype)
      other.update_measure(:subtype)
      expect(Ticket.stale(:subtype)).to be_empty
      ticket.update!(department: "returns") # the scale moved under the stored answer
      expect(Ticket.stale(:subtype)).to eq([ticket])
      expect(Ticket.stale(:subtype).to_sql).not_to include("json_extract")
    end

    it "remeasures with update_measure_all, leaving nothing stale" do
      ticket
      Ticket.create!(body: "y")
      Ticket.stale(:escalate).update_measure_all(:escalate)
      expect(Ticket.stale(:escalate)).to be_empty
      expect(Ticket.pluck(:escalate)).to eq([true, true])
      expect(requests.size).to eq(2)
    end
  end

  describe "rake s1:remeasure[Model,col]" do
    it "runs Model.stale(col).update_measure_all(col) in batches, reporting progress" do
      ticket
      Ticket.create!(body: "y")
      Ticket.create!(body: "z")
      rake = Rake::Application.new
      Rake.application = rake
      rake.define_task(Rake::Task, :environment)
      load File.expand_path("../../lib/tasks/s1.rake", __dir__)
      out = StringIO.new
      $stdout = out
      begin
        ENV["BATCH"] = "2"
        rake["s1:remeasure"].invoke("Ticket", "escalate")
      ensure
        $stdout = STDOUT
        ENV.delete("BATCH")
      end
      expect(out.string).to eq("Ticket.stale(:escalate): 3 row(s)\n  2/3\n  3/3\n")
      expect(Ticket.stale(:escalate)).to be_empty
      expect(requests.size).to eq(3)
    end
  end
end
