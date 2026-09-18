# frozen_string_literal: true

# Two fields labelled differently, one not: the plan splits them by label.
class LabelledSharer < ActiveRecord::Base
  self.table_name = "sharers"
  include S1::Measurable

  measurable_as { { note: "a note" } }
  judges :a, "Is it A?", metadata: { call_type: "alpha" }
  judges :b, "Is it B?", metadata: { call_type: "beta", team: "ops" }
end

# A trigger's measurement carries the field's label through the job.
class LabelledRouting < ActiveRecord::Base
  self.table_name = "routings"
  include S1::Measurable

  measurable_as { { transcript: transcript } }
  judges :urgent, "Does the caller need a reply today?", measure_on: :save, metadata: { call_type: "triage" }
end

RSpec.describe "metadata: labels on the Request" do
  let(:firm) { Firm.create!(name: "Dudley") }
  let(:call) { PhoneCall.create!(firm: firm, transcript: "I was rear-ended yesterday") }
  let(:requests) { [] }

  before do
    stub_s1(is_lead: 0.9, a: 0.9, b: 0.1, urgent: 0.8, noul: 0.9, one: 0.9)
    S1.on_result { |_result, request| requests << request }
    LabelledSharer.delete_all
  end

  def labels = requests.map(&:metadata)

  describe "on a record's State" do
    it "rides from as(), beside the owner and the form, and never reaches the form" do
      call.as(:window, last: 9, metadata: { call_type: "pre_score" }).measure { |q| q.judge :is_lead, "Lead?" }

      expect(requests.last.metadata).to eq(call_type: "pre_score")
      expect(requests.last.options).to include(owner: call, form: :window)
      expect(requests.last.state).to eq(transcript: "yesterday")
    end

    it "carries through a lens and onto another form" do
      state = call.as(:review, metadata: { call_type: "pre_score" })
      state.given(note: "n").judge("Lead?")
      state.to_s1(as: :window).judge("Lead?")

      expect(labels).to eq([{ call_type: "pre_score" }] * 2)
      expect(requests.last.options[:form]).to eq(:window)
    end

    it "merges a verb's over the State's" do
      call.as(metadata: { call_type: "routing", firm: 1 }).judge("Lead?", metadata: { firm: 2 })
      expect(labels).to eq([{ call_type: "routing", firm: 2 }])
    end
  end

  describe "on the record's verbs" do
    it "rides from judge?, measure, update_measure and a declared column" do
      call.judge?("Lead?", metadata: { call_type: "a" })
      call.measure(metadata: { call_type: "b" }) { |q| q.judge :one, "One?" }
      call.update_measure(metadata: { call_type: "c" }) { |q| q.judge :is_lead, "Lead?" }
      LabelledSharer.create!.judge?(:a, metadata: { call_type: "d" })

      expect(labels.map { |m| m[:call_type] }).to eq(%w[a b c d])
      expect(call.reload.is_lead).to be(true)
    end
  end

  describe "on a relation" do
    it "labels every record's call" do
      other = PhoneCall.create!(firm: firm, transcript: "Wrong number")
      PhoneCall.where(id: [call.id, other.id]).where_is("a lead", concurrency: 2, metadata: { call_type: "iris", ai_chat_id: 7 })
      PhoneCall.where(id: call.id).update_measure_all(metadata: { call_type: "backfill" }) { |q| q.judge :is_lead, "Lead?" }

      expect(labels).to eq(([{ call_type: "iris", ai_chat_id: 7 }] * 2) + [{ call_type: "backfill" }])
      expect(requests.map { |r| r.options[:owner] }).to contain_exactly(call, other, call)
    end
  end

  describe "in the background" do
    it "travels with update_measure_later into the job" do
      call.update_measure_later(metadata: { call_type: "later", tags: %w[a b] }) { |q| q.judge :is_lead, "Lead?" }
      perform_enqueued_jobs

      expect(labels).to eq([{ call_type: "later", tags: %w[a b] }])
    end

    it "labels a trigger's measurement with the field's metadata" do
      LabelledRouting.create!(transcript: "Call me back today")
      perform_enqueued_jobs

      expect(labels).to eq([{ call_type: "triage" }])
    end
  end

  describe "declared on a field" do
    let(:sharer) { LabelledSharer.create! }

    it "splits fields labelled differently into separate calls, each with its own label" do
      sharer.measure(:a, :b)
      expect(labels).to contain_exactly({ call_type: "alpha" }, { call_type: "beta", team: "ops" })
      expect(LabelledSharer.s1_plan(:a, :b).size).to eq(2)
      expect(LabelledSharer.s1_plan(:a).to_s).to include('metadata: {call_type: "alpha"}').or include('metadata: {:call_type=>"alpha"}')
    end

    it "is the base the call's metadata merges over" do
      sharer.measure(:b, metadata: { team: "sales", job: 1 })
      expect(labels).to eq([{ call_type: "beta", team: "sales", job: 1 }])
    end

    it "keeps an unlabelled question in the call's own batch" do
      sharer.measure(:a) { |q| q.judge :one, "One?" }
      expect(labels).to contain_exactly({ call_type: "alpha" }, {})
    end

    it "is checked at declaration" do
      define = lambda do |metadata|
        Class.new(ActiveRecord::Base) do
          self.table_name = "sharers"
          include S1::Measurable

          judges :a, "A?", metadata: metadata
        end
      end

      expect { define.call("alpha") }.to raise_error(ArgumentError, /metadata: "alpha" reads as a label/)
      expect { define.call(%w[alpha]) }.to raise_error(S1::ValidationError, /:a metadata: is a Hash/)
      expect { define.call(owner: Object.new) }.to raise_error(S1::ValidationError, /:a metadata\[:owner\] is a Object/)
    end
  end
end
