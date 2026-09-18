# frozen_string_literal: true

RSpec.describe S1::MeasureJob do
  let(:firm) { Firm.create!(name: "Dudley") }
  let(:call) { PhoneCall.create!(firm: firm, transcript: "I was rear-ended yesterday") }

  before { stub_s1(is_lead: 0.9, case_type: :mva) }

  it "enqueues the built questions and applies them on perform" do
    seen = nil
    stub_s1 { |req| seen = req and { is_lead: 0.9, case_type: :mva } }

    call.update_measure_later(as: :window, last: 9) do |q, record|
      q.judge  :is_lead,   "Lead? (#{record.id})", true: "a new matter"
      q.choose :case_type, "Type?", mva: "car", slip: "fall"
    end
    expect(enqueued_jobs.map { |j| j["job_class"] }).to eq(["S1::MeasureJob"])
    expect(call.reload.is_lead).to be_nil

    perform_enqueued_jobs
    call.reload
    expect(call.is_lead).to be(true)
    expect(call.case_type).to eq("mva")
    expect(seen.state).to eq(transcript: "yesterday")
    expect(seen.questions[:is_lead].instructions).to eq("Lead? (#{call.id})")
    expect(seen.questions[:is_lead].criteria).to eq("true" => "a new matter")
    expect(seen.options[:form]).to eq(:window)
  end

  it "raises on an invalid save instead of dropping the measurement silently" do
    call.update_measure_later { |q| q.judge :is_lead, "Lead?" }
    allow_any_instance_of(PhoneCall).to receive(:valid?).and_return(false)
    expect { perform_enqueued_jobs }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "names a record that isn't measurable instead of failing on a missing method" do
    record = Struct.new(:id).new(1)

    expect { described_class.perform_now(record, nil, {}) }
      .to raise_error(ArgumentError, "#{record} is not measurable? Does it include S1::Measurable?")
  end

  it "retries transient errors" do
    expect(described_class.rescue_handlers.map(&:first)).to include("S1::TransientError")
  end

  it "is S1::AskJob, so a payload enqueued under the earlier name still deserializes and performs" do
    expect(S1::AskJob).to be(described_class)
    call.update_ask_later { |q| q.noul :is_lead, "Lead?" }
    payload = enqueued_jobs.last.merge("job_class" => "S1::AskJob")
    clear_enqueued_jobs
    expect(ActiveJob::Base.deserialize(payload)).to be_a(described_class)
    ActiveJob::Base.execute(payload)
    expect(call.reload.is_lead).to be(true)
  end
end
