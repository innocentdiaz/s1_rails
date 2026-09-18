# frozen_string_literal: true

# The second review's findings, each closed the same way as the first's: a silent misread
# becomes a raise that names the spelling, a convention says what it decided, and the two
# spellings of one thing run one code path. A trigger sees every change of the transaction and
# nothing that is not one; the default form never carries a measurement back as evidence; a
# relation reads the database on the calling thread and hands only the provider call to a thread.
RSpec.describe "the reviewed foot-guns" do
  let(:requests) { [] }
  let(:ticket) { Ticket.create!(body: "I have asked three times. Can I talk to a real person?", plan: "gold") }

  def answers(**canned) = stub_s1 { |req| requests << req and canned }
  def fresh(table, &) = Class.new(ActiveRecord::Base) { self.table_name = table }.tap { |k| k.include(S1::Measurable) }.tap { |k| k.class_eval(&) }

  describe "a block's criteria: on a declared score is that scale, never the declaration's" do
    it "measures over the inline levels, and refuses the write as the positional spelling is refused" do
      answers(severity: "low")
      result = ticket.measure { |q| q.score :severity, "How bad?", criteria: %w[low high] }
      expect(requests.last.questions[:severity].levels).to eq(%w[low high])
      expect(result[:severity].levels.map(&:to_s)).to eq(%w[low high])
      expect(result[:severity].level).to eq("low")
      expect { ticket.update_measure { |q| q.score :severity, "How bad?", criteria: %w[low high] } }
        .to raise_error(ArgumentError, /:severity is declared over \["cosmetic", "degraded", "blocking"\]; a measurement over \["low", "high"\]/)
      expect(ticket.reload).to have_attributes(severity: nil, s1_answers: nil)
    end

    it "raises when a score's stored labels are another size than the levels it was asked over" do
      answers(severity: 1)
      expect { ticket.measure { |q| q.score(:severity, "q", "x", "y").stores(:severity, %w[a b c]) } }
        .to raise_error(S1::ValidationError,
                        'Ticket: :severity was asked over ["x", "y"] but stores ["a", "b", "c"]; a scale of another size is another question')
    end
  end

  describe "a sequenced predecessor on a float score column enters the lens as its stored collapse" do
    it "reads the argmax from the audit, so the lens, the audit and measurement(:col) agree; without one the read raises" do
      klass = stub_const("Expected", Class.new(PhoneCall) do
        scores :quality_position, "q", :cosmetic, :degraded, :blocking
        judges :is_lead, "Lead, given `quality_position`?", after: :quality_position
      end)
      stub_s1 do |_req|
        { quality_position: { legend: { 0 => "cosmetic", 1 => "degraded", 2 => "blocking" },
                              probabilities: { "0" => 0.4, "1" => 0.1, "2" => 0.5 }, confidence: 1.0 } }
      end
      row = klass.create!(firm: Firm.create!(name: "f"), transcript: "x")
      row.update_measure(:quality_position)
      expect(row.reload.quality_position).to eq(1.1)
      expect(row.s1_answers["quality_position"]["value"]).to eq("blocking")
      expect(row.measurement(:quality_position).collapse).to eq("blocking")
      expect(row.s1_request(:is_lead).state).to include(quality_position: "blocking")
      row.update_column(:s1_answers, nil)
      expect { row.reload.s1_request(:is_lead) }
        .to raise_error(ArgumentError, "Expected: :quality_position holds 1.1, not measured; a float or decimal column keeps the " \
                                       "expectation, not the category — measure it: update_measure(:quality_position)")
    end

    it "reads a float noul column's verdict at the threshold stamped in the audit, so the lens and measurement(:col) agree" do
      klass = stub_const("Massed", Class.new(PhoneCall) do
        judges :lead_probability, "Lead?"
        chooses :case_type, "Which, given `lead_probability`?", returns: "R", billing: "B", after: :lead_probability, siblings: false
      end)
      stub_s1(lead_probability: 0.7, case_type: :billing)
      row = klass.create!(firm: Firm.create!(name: "f"), transcript: "x")
      row.update_measure(:lead_probability, threshold: 0.8)
      expect(row.reload.lead_probability).to eq(0.7)
      expect(row.s1_answers["lead_probability"]).to include("value" => "false", "threshold" => 0.8)
      expect(row.measurement(:lead_probability).collapse).to be(false)
      expect(row.s1_request(:case_type).state).to include(lead_probability: false)
      expect(row.s1_request(:case_type, threshold: 0.6).state).to include(lead_probability: true)
      row.update_measure(:lead_probability)
      expect(row.reload.measurement(:lead_probability).threshold).to eq(0.5)
      expect(row.s1_request(:case_type).state).to include(lead_probability: true)
      S1.config.threshold = 0.9
      expect(row.measurement(:lead_probability).collapse).to be(true)
      expect(row.s1_request(:case_type).state).to include(lead_probability: true)
      row.update_measure(:case_type)
      expect(row.s1_result.to_h).to eq(case_type: :billing)
      row.update_column(:s1_answers, nil)
      expect { row.reload.s1_request(:case_type) }
        .to raise_error(ArgumentError, "Massed: :lead_probability holds 0.7, not measured at a threshold; a float or decimal column keeps " \
                                       "the distribution — declare threshold: on it, or add an s1_answers column and measure it: " \
                                       "update_measure(:lead_probability)")
      expect { klass.s1_collapsed(:lead_probability, row) }.to raise_error(ArgumentError, /not measured at a threshold/)
      expect(row.s1_request(:case_type, threshold: 0.6).state).to include(lead_probability: true)
      expect(klass.s1_collapsed(:lead_probability, row, threshold: 0.6)).to be(true)
    end

    it "refuses after: a float score column at verify! when there is no s1_answers to read it from" do
      klass = fresh("sharers") do
        scores :shared, "q", :x, :y
        judges :a, "q", after: :shared
      end
      expect { klass.s1_verify_fields! }
        .to raise_error(ArgumentError, /:a after: :shared — a score on a float column keeps the expectation, not the level; add an s1_answers column/)
    end

    it "refuses after: a float noul column at verify! with no s1_answers and no threshold: — a declared one is a stamp by declaration" do
      klass = fresh("sharers") do
        judges :shared, "q"
        judges :a, "q", after: :shared
      end
      expect { klass.s1_verify_fields! }
        .to raise_error(ArgumentError, "#{klass}: :a after: :shared — a judge on a float column keeps the mass, not the verdict; " \
                                       "declare threshold: on it, or add an s1_answers column so the lens reads the stored measurement's collapse")
      stamped = fresh("sharers") do
        judges :shared, "q", threshold: 0.6
        judges :a, "q", after: :shared
      end
      expect { stamped.s1_verify_fields! }.not_to raise_error
      row = stamped.new(shared: 0.7)
      expect(stamped.s1_collapsed(:shared, row)).to be(true)
      S1.config.threshold = 0.9
      expect(stamped.s1_collapsed(:shared, row)).to be(true)
      expect(stamped.s1_collapsed(:shared, row, threshold: 0.8)).to be(false)
    end

    it "reads a float noul column at the threshold stamped in the audit before the field's, in the lens and in s1_collapsed alike" do
      klass = stub_const("Stamped", Class.new(PhoneCall) do
        judges :lead_probability, "Lead?", threshold: 0.6
        chooses :case_type, "Which, given `lead_probability`?", returns: "R", billing: "B", after: :lead_probability, siblings: false
      end)
      stub_s1(lead_probability: 0.65, case_type: :billing)
      row = klass.create!(firm: Firm.create!(name: "f"), transcript: "x")
      row.update_measure(:lead_probability)
      expect(row.reload.s1_answers["lead_probability"]).to include("value" => "true", "threshold" => 0.6)
      stricter = stub_const("Stricter", Class.new(klass) { judges :lead_probability, "Lead?", threshold: 0.9 })
      later = stricter.find(row.id)
      expect(later.measurement(:lead_probability).collapse).to be(true)
      expect(later.s1_request(:case_type).state).to include(lead_probability: true)
      expect(stricter.s1_collapsed(:lead_probability, later)).to be(true)
      expect(stricter.s1_collapsed(:lead_probability, later, threshold: 0.9)).to be(false)
      expect(later.s1_request(:case_type, threshold: 0.9).state).to include(lead_probability: false)
      expect(later).not_to be_stale(:lead_probability)
      stricter.find(row.id).update_measure(:lead_probability)
      expect(stricter.find(row.id).s1_answers["lead_probability"]).to include("value" => "false", "threshold" => 0.9)
      expect(stricter.find(row.id).s1_request(:case_type).state).to include(lead_probability: false)
    end

    it "names a decimal score column's value readably when it has no audit to read the level from" do
      klass = stub_const("Decimal", Class.new(PhoneCall) { scores :lead_mass, "Mass?", :low, :mid, :high, siblings: false })
      expect { klass.s1_collapsed(:lead_mass, klass.new(lead_mass: 1.5)) }
        .to raise_error(ArgumentError, "Decimal: :lead_mass holds 1.5, not measured; a float or decimal column keeps the expectation, " \
                                       "not the category — measure it: update_measure(:lead_mass)")
    end
  end

  describe "the default form never carries a measurement back as evidence" do
    it "renders the attributes less the key, the timestamps, the audit, the measured columns and their siblings" do
      klass = stub_const("Bare", fresh("tickets") { judges :escalate, "Human?", threshold: 0.7 })
      answers(escalate: 0.9)
      row = klass.create!(body: "hello", plan: "gold")
      row.update_measure(:escalate)
      state = row.s1_request(:escalate).state
      expect(state.keys).to contain_exactly("body", "plan", "department", "department_confidence", "severity", "severity_index",
                                            "severity_expectation", "priority", "grade", "subtype")
      expect(state).not_to include("escalate", "escalate_probability", "s1_answers", "id", "created_at", "updated_at")
      expect(klass.s1_plan.to_s).to include("default form (attributes): body, plan, department")
    end

    it "warns at verify! when a field would measure through no declared form, naming the attributes it sends" do
      log = StringIO.new
      S1.config.logger = Logger.new(log)
      fresh("tickets") { judges :escalate, "q", siblings: false }.s1_verify_fields!
      expect(log.string).to include("measures [:escalate] through no declared form: the evidence is the attributes [\"body\", \"plan\"")
      log.truncate(0)
      formed = fresh("tickets") do
        measurable_as(:planned) { { body: body, plan: plan } }
        judges :escalate, "q", siblings: false, as: :planned
      end
      formed.s1_verify_fields!
      expect(log.string).not_to include("through no declared form")
      expect(formed.s1_plan.to_s).not_to include("default form")
    end
  end

  describe "a trigger sees every change of the transaction, and nothing that is not one" do
    before { answers(escalate: 0.9, department: :billing) }

    it "fires for an attribute a later before_save set, on create and on update" do
      klass = stub_const("Derived", Class.new(Ticket) do
        before_save { self.plan = body.to_s.upcase }
        judges :escalate, "q", measure_on: :plan
      end)
      row = klass.create!(body: "hello")
      expect(row.saved_changes.keys).to include("plan")
      expect(enqueued_jobs.map { |j| j["arguments"][5] }).to eq([%w[escalate]])
      clear_enqueued_jobs
      row.update!(body: "changed")
      expect(enqueued_jobs.map { |j| j["arguments"][5] }).to eq([%w[escalate]])
      clear_enqueued_jobs
      row.update!(department: "billing")
      expect(enqueued_jobs).to be_empty
    end

    it "does not fire on a touch, nor re-fire the last transaction's attribute trigger, nor on a save that changed nothing" do
      klass = stub_const("Touched", Class.new(Ticket) do
        judges  :escalate,   "q", measure_on: :save
        chooses :department, "q", **Ticket::DEPARTMENTS, measure_on: :body
      end)
      row = klass.create!(body: "c")
      clear_enqueued_jobs
      row.touch
      expect(enqueued_jobs).to be_empty
      row.save!
      expect(enqueued_jobs).to be_empty
      row.update!(body: "d")
      expect(enqueued_jobs.map { |j| j["arguments"][5] }).to contain_exactly(%w[escalate], %w[department])
      clear_enqueued_jobs
      klass.transaction { row.update!(body: "e") and row.touch }
      expect(enqueued_jobs.map { |j| j["arguments"][5] }).to contain_exactly(%w[escalate], %w[department])
    end

    it "treats assign_measure followed by the caller's save! as the measurement's own write" do
      klass = stub_const("Assigned", Class.new(Ticket) do
        judges  :escalate,   "q", measure_on: :save
        chooses :department, "q", **Ticket::DEPARTMENTS, measure_on: :save
      end)
      row = klass.create!(body: "x")
      clear_enqueued_jobs
      requests.clear
      row.assign_measure(:escalate)
      row.save!
      expect(requests.map { |r| r.questions.keys }).to eq([[:escalate]])
      expect(enqueued_jobs).to be_empty
      row.body = "y"
      row.assign_measure(:escalate)
      row.save!
      expect(enqueued_jobs.map { |j| j["arguments"][5] }).to eq([%w[department]])
      perform_enqueued_jobs
      expect(requests.map { |r| r.questions.keys }).to eq([[:escalate], [:escalate], [:department]])
    end

    it "reads an attribute list as a set: two orders are one trigger, and a sequenced field may spell it either way" do
      klass = stub_const("Ordered", Class.new(Ticket) do
        judges  :escalate,   "q", measure_on: %i[body plan]
        chooses :department, "q", **Ticket::DEPARTMENTS, measure_on: %i[plan body], after: :escalate
      end)
      expect(klass.s1_triggers.values).to eq([%i[escalate department]])
      klass.create!(body: "x")
      expect(enqueued_jobs.map { |j| j["arguments"][5] }).to eq([%w[escalate department]])
    end
  end

  describe "an undeclared enum column takes a choice, or a score over integers, and refuses the rest naming the macro" do
    it "raises the gem's own error before Rails' for a noul into an enum" do
      klass = fresh("deliveries") { enum :note, { fragile: "fragile", bulky: "bulky" } }
      answers(note: 0.5)
      row = klass.create!
      expect { row.update_measure { |q| q.judge :note, "q?" } }
        .to raise_error(ArgumentError, "#{klass}: a noul does not collapse into :note (an enum); declare it with chooses (or score_enum)")
      answers(note: :bulky)
      row.update_measure { |q| q.choose :note, "q?", fragile: "a", bulky: "b" }
      expect(row.reload.note).to eq("bulky")
    end
  end

  describe "a measured_against key that is a predecessor's name is refused as given: is" do
    it "at verify!, when the declared lens can be read on a blank record" do
      klass = Class.new(Routing) { measured_against { { kind: "from measured_against" } } }
      expect { klass.s1_verify_fields! }.to raise_error(ArgumentError, /:case_type measured_against :kind is a field it comes after: its collapse is that key/)
    end

    it "at the call, when it cannot" do
      klass = stub_const("LensedKind", Class.new(Routing) { measured_against { { kind: transcript.upcase } } })
      row = klass.create!(transcript: "x", kind: "new_case")
      clear_enqueued_jobs
      expect { row.s1_request(:kind, :case_type) }
        .to raise_error(ArgumentError, /measured_against :kind is a field :case_type comes after; its collapse is that key/)
    end
  end

  describe "update_measure_later evaluates a Proc at the top of given: on the record, as every other path does" do
    it "enqueues the lens as its value" do
      answers(kind: :new_case)
      row = Routing.create!(transcript: "x")
      clear_enqueued_jobs
      row.update_measure_later(:kind, given: { p: -> { "p-#{transcript}" } })
      expect(enqueued_jobs.last["arguments"][4]).to include("p" => "p-x")
      perform_enqueued_jobs
      expect(requests.last.state).to include(p: "p-x")
    end
  end

  describe "the declaration names its own spelling" do
    it "refuses s1_plan for a field that is not measured" do
      expect { Ticket.s1_plan(:nope) }.to raise_error(ArgumentError, "Ticket.s1_plan: [:nope] are not measured fields")
      expect { Ticket.s1_plan(:escalate, :nope) }.to raise_error(ArgumentError, /\[:nope\] are not measured fields/)
    end

    it "refuses a chooses or scores over { true, false }, naming judges — measured_field already resolves them so" do
      expect { stub_const("YesNo", Class.new(Ticket)).chooses :department, "Is it?", true: "yes it is", false: "no" }
        .to raise_error(ArgumentError, "YesNo: chooses :department over { true, false } is a dichotomous scale; declare it with judges")
      expect { Class.new(Ticket) { chooses :department, "Is it?", categories: %i[true false] } }.to raise_error(ArgumentError, /declare it with judges/)
      expect { Class.new(Ticket) { scores :severity, "Is it?", :false, :true } }.to raise_error(ArgumentError, /scores :severity over \{ true, false \}/)
      expect(Class.new(Ticket) { measured_field :escalate, "Is it?", true: "yes", false: "no" }.s1_fields[:escalate][:kind]).to eq(:noul)
    end
  end

  describe "a declared field the record cannot write raises, never an audit of a value the row does not hold" do
    it "raises for a select that left the column out" do
      answers(department: :billing)
      narrow = Ticket.select(:id, :body, :plan).find(ticket.id)
      expect { narrow.update_measure(:department) }
        .to raise_error(ArgumentError, "Ticket: :department is a measured field this record was loaded without (a select?); load the column to write it")
      expect(requests.size).to eq(1)
      expect(ticket.reload).to have_attributes(department: nil, s1_answers: nil)
    end

    it "verifies a model once, at its first measurement, when verify! never ran" do
      klass = stub_const("Ghostly", fresh("tickets") { judges :ghost, "Is there a ghost?" })
      answers(ghost: 0.9)
      row = klass.create!(body: "x")
      expect { row.update_measure(:ghost) }.to raise_error(ArgumentError, "Ghostly: measured field :ghost is not a column")
      expect(requests).to be_empty
      expect(row.reload.s1_answers).to be_nil
    end
  end

  describe "the conventions say what they decided" do
    it "notes every sibling column claimed by name at verify!, and s1_plan prints them per field" do
      log = StringIO.new
      S1.config.logger = Logger.new(log)
      Ticket.s1_verify_fields!
      expect(log.string).to include("Ticket: :escalate writes escalate_probability (probability); :department writes department_confidence (confidence); " \
                                    ":severity writes severity_expectation (expectation), severity_index (index)")
      expect(Ticket.s1_plan(:severity).to_s).to include("severity (writes severity_expectation, severity_index)")
      log.truncate(0)
      mapped = fresh("phone_calls") { judges :is_lead, "Lead?", siblings: { probability: :lead_probability } }
      mapped.s1_verify_fields!
      expect(log.string).not_to include("writes")
    end

    it "warns about positional levels beside an _index sibling on a string column, as on an integer column" do
      log = StringIO.new
      S1.config.logger = Logger.new(log)
      Class.new(Ticket) { scores :severity, "q", :a, :b, :c }.s1_verify_fields!
      expect(log.string).to include(":severity is a score with an _index sibling with positional levels — give explicit indexes")
      log.truncate(0)
      Class.new(Ticket) { scores :severity, "q", :a, :b, :c, indexes: { a: 1, b: 2, c: 3 } }.s1_verify_fields!
      expect(log.string).not_to include("positional levels")
    end
  end

  describe "a sequenced lens is a category on the scale, as the column holds it" do
    it "refuses a blank, and a label the scale no longer has, naming the remeasure" do
      answers(case_type: :mva)
      row = Routing.create!(transcript: "x", kind: "")
      clear_enqueued_jobs
      expect { row.s1_request(:case_type) }.to raise_error(ArgumentError, /:kind has not been measured, and :case_type is judged given it/)
      row.update!(kind: "legacy")
      expect { row.s1_request(:case_type) }
        .to raise_error(ArgumentError,
                        'Routing: :kind holds "legacy", which is not on its scale ["new_case", "existing", "other"]; measure it again — update_measure(:kind)')
      expect(requests).to be_empty
    end
  end

  describe "a score's mass is read by rank through the legend, whatever keys the wire used" do
    it "keys _probabilities and the audit by rank from a 1-based legend, and rehydrates" do
      klass = fresh("gradings") { scores :priority, "How urgent?", { "can wait" => 10, "today" => 20, "now" => 30 } }
      stub_s1 do |_req|
        { priority: { expectation: 0.0, legend: { "1" => "can wait", "2" => "today", "3" => "now" },
                      probabilities: { "1" => 0.1, "2" => 0.7, "3" => 0.2 }, confidence: 0.9 } }
      end
      row = klass.create!(body: "x")
      row.update_measure(:priority)
      result = row.s1_result
      expect(result[:priority].expectation).to be_within(1e-9).of(1.1)
      expect(result[:priority].key).to eq(1)
      expect(result[:priority].level.position).to eq(1)
      expect(result[:priority].probabilities).to eq("0" => 0.1, "1" => 0.7, "2" => 0.2)
      expect(row.reload.priority).to eq(20)
      expect(row.priority_probabilities).to eq("can wait" => 0.1, "today" => 0.7, "now" => 0.2)
      expect(row.s1_answers["priority"]).to include("probabilities" => { "0" => 0.1, "1" => 0.7, "2" => 0.2 }, "value" => "today", "position" => 1)
      expect(row.measurement(:priority).level).to eq("today")
      expect(row.measurement(:priority).probabilities).to eq("0" => 0.1, "1" => 0.7, "2" => 0.2)
    end
  end

  describe "a relation reads the database on the calling thread and hands only the provider call to a thread" do
    it "runs the block, a field's own form and lens, and the writes on this thread, with the calls in flight together" do
      rows = 3.times.map { |i| Ticket.create!(body: "b#{i}") }
      in_flight = 0
      most = 0
      lock = Mutex.new
      stub_s1 do |_req|
        lock.synchronize { most = [most, in_flight += 1].max }
        sleep 0.05
        lock.synchronize { in_flight -= 1 }
        { escalate: 0.9, department: :billing }
      end
      results = Ticket.where(id: rows.map(&:id)).update_measure_all(:department, concurrency: 3) do |q, row|
        q.judge :escalate, "Human? (#{row.class.count} tickets, #{row.class.find(row.id).body})"
      end
      expect(results.size).to eq(3)
      expect(most).to be >= 2
      expect(rows.map { |r| r.reload.department }).to eq(%w[billing billing billing])
      expect(rows.map(&:escalate)).to eq([true, true, true])
    end
  end
end
