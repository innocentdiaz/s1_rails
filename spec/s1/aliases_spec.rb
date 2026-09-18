# frozen_string_literal: true

# Every pre-theory spelling still works, as a plain alias of the theory's name.
RSpec.describe "compatibility aliases" do
  let(:delivery) { Delivery.create!(status: :attempted) }
  let(:state) { delivery.as }
  let(:questions) { S1::Measurable::Questions.new(delivery) }

  def same_method?(object, old, new) = object.method(old) == object.method(new)

  it "S1::Measurable::Subject is S1::Measurable::State, an S1::State" do
    expect(S1::Measurable::Subject).to be(S1::Measurable::State)
    expect(S1::Measurable::State.superclass).to be(S1::State)
    expect(S1::Evaluable).to be(S1::Measurable)
  end

  it "S1::AskJob is S1::MeasureJob; NoulValidator is JudgeValidator" do
    expect(S1::AskJob).to be(S1::MeasureJob)
    expect(NoulValidator).to be(JudgeValidator)
  end

  it "record verbs: ask / batch / ask_about are measure; noul is judge; noul? / ask? are judge?" do
    %i[ask batch ask_about].each { |old| expect(same_method?(delivery, old, :measure)).to be(true), old.to_s }
    expect(same_method?(delivery, :noul, :judge)).to be(true)
    expect(same_method?(delivery, :noul?, :judge?)).to be(true)
    expect(same_method?(delivery, :ask?, :judge?)).to be(true)
    expect(same_method?(delivery, :as_measurable, :as)).to be(true)
    expect(same_method?(delivery, :against, :given)).to be(true)
  end

  it "record writes: update_ask / assign_ask / update_ask_later are the update_measure forms" do
    expect(same_method?(delivery, :update_ask, :update_measure)).to be(true)
    expect(same_method?(delivery, :assign_ask, :assign_measure)).to be(true)
    expect(same_method?(delivery, :update_ask_later, :update_measure_later)).to be(true)
  end

  it "update_judge / assign_judge spell update_measure / assign_measure, bangs, _later and _all included" do
    %i[update_judge update_ask].each { |old| expect(same_method?(delivery, old, :update_measure)).to be(true), old.to_s }
    %i[update_judge! update_ask!].each { |old| expect(same_method?(delivery, old, :update_measure!)).to be(true), old.to_s }
    expect(same_method?(delivery, :assign_judge, :assign_measure)).to be(true)
    expect(same_method?(delivery, :update_judge_later, :update_measure_later)).to be(true)
    expect(same_method?(Delivery, :update_judge_all, :update_measure_all)).to be(true)
    expect(same_method?(state, :update_judge, :update_measure)).to be(true)
    expect(same_method?(state, :update_judge!, :update_measure!)).to be(true)
    expect(same_method?(state, :assign_judge, :assign_measure)).to be(true)
  end

  it "class macros: s1_state is measurable_as; measured_given is measured_against; s1_field and friends are measured_field" do
    expect(same_method?(Delivery, :s1_state, :measurable_as)).to be(true)
    expect(same_method?(Delivery, :measured_given, :measured_against)).to be(true)
    %i[s1_field measured_attribute measurable_field].each { |old| expect(same_method?(Delivery, old, :measured_field)).to be(true), old.to_s }
    %i[measured_enum choice_enum].each { |old| expect(same_method?(Delivery, old, :s1_enum)).to be(true), old.to_s }
    expect(same_method?(Delivery, :s1_choices, :s1_categories)).to be(true)
  end

  it "relation verbs: ask_all is measure_all; update_ask_all is update_measure_all; the Enumerable and s1_ spellings" do
    expect(same_method?(Delivery, :ask_all, :measure_all)).to be(true)
    expect(same_method?(Delivery, :update_ask_all, :update_measure_all)).to be(true)
    expect(same_method?(Delivery, :measure_select, :where_judged)).to be(true)
    expect(same_method?(Delivery, :s1_select, :where_judged)).to be(true)
    expect(same_method?(Delivery, :measure_reject, :where_judged_not)).to be(true)
    expect(same_method?(Delivery, :s1_reject, :where_judged_not)).to be(true)
    expect(same_method?(Delivery, :measure_grep, :where_same_as)).to be(true)
    expect(same_method?(Delivery, :against, :given)).to be(true)
  end

  it "Measurable::State: ask / batch / ask_about are measure; noul is judge; update_ask / assign_ask are the measure forms" do
    %i[ask batch ask_about].each { |old| expect(same_method?(state, old, :measure)).to be(true), old.to_s }
    expect(same_method?(state, :noul, :judge)).to be(true)
    expect(same_method?(state, :update_ask, :update_measure)).to be(true)
    expect(same_method?(state, :assign_ask, :assign_measure)).to be(true)
    expect(same_method?(state, :against, :given)).to be(true)
    expect(same_method?(state, :state, :rendered)).to be(true)
  end

  it "the lens's old name, context: Measurable::State#context, State.new(context:), Given#s1_context" do
    lensed = delivery.as(given: { policy: "p" })
    expect(same_method?(lensed, :context, :lens)).to be(true)
    expect(lensed.context).to eq(policy: "p")
    expect(S1::Measurable::State.new(delivery, context: { policy: "p" }).rendered).to eq(lensed.rendered)
    expect(S1::Measurable::State.new(delivery, context: { policy: "p" }).lens).to eq(policy: "p")
    relation = Delivery.given(policy: "p")
    expect(relation.s1_context).to eq(policy: "p")
    relation.s1_context = { policy: "q" }
    expect(relation.s1_lens).to eq(policy: "q")
  end

  it "class macros: noul_field is judges; choice_field is chooses; score_field is scores; s1_enum and measured_enum are choice_enum" do
    expect(same_method?(Delivery, :noul_field, :judges)).to be(true)
    expect(same_method?(Delivery, :choice_field, :chooses)).to be(true)
    expect(same_method?(Delivery, :score_field, :scores)).to be(true)
    expect(same_method?(Delivery, :measured_score_enum, :score_enum)).to be(true)
  end

  it "Measurable::Questions: noul is judge; choice is gone (a noun would yield a distribution); choices: is categories:" do
    expect(same_method?(questions, :noul, :judge)).to be(true)
    expect(questions).not_to respond_to(:choice)
    expect { questions.choice(:a, "?", categories: { x: "1", y: "2" }) }.to raise_error(NoMethodError)
    questions.choose(:a, "?", categories: { x: "1", y: "2" })
    questions.choose(:b, "?", choices: { x: "1", y: "2" })
    questions.choose(:c, "?", criteria: { x: "1", y: "2" })
    expect(questions.to_h.values.map(&:categories).uniq).to eq([%w[x y]])
  end

  it "the old spellings still measure, through the aliases" do
    stub_s1(noul: 0.9, status: :delivered, note_needed: 0.9)
    expect(delivery.noul?("q?")).to be(true)
    expect(delivery.noul("q?")).to be_a(S1::Answer::Noul)
    expect(delivery.ask { |q| q.noul :note_needed, "q?" }.answers.keys).to eq([:note_needed])
    expect(delivery.update_ask { |q| q.choose :status }).to be(true)
    expect(delivery.s1_result.answers.keys).to eq([:status])
    expect { delivery.update_ask { |q| q.choice :status } }.to raise_error(NoMethodError)
    expect(delivery.reload).to be_delivered
    expect(Delivery.where(id: delivery.id).ask_all(:note_needed).values.first.answers.keys).to eq([:note_needed])
  end
end
