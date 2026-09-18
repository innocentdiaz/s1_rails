# frozen_string_literal: true

# The declaration DSL: judges / chooses / scores, the options every macro takes, the
# registry, the resolving measured_field, the enums, and the boot check.
RSpec.describe "declarations" do
  let(:ticket) { Ticket.create!(body: "I have asked three times. Can I talk to a real person?", plan: "gold") }

  def fields(&) = Class.new(Ticket, &).s1_fields

  describe "the registry" do
    it "is frozen, one entry per field, in the declared key order, absent keys omitted" do
      expect(Ticket.s1_fields).to be_frozen
      expect(Ticket.s1_fields.values).to all(be_frozen)
      expect(Ticket.s1_fields.keys).to eq(%i[escalate department severity priority subtype grade])
      expect(Ticket.s1_fields[:escalate]).to eq(
        kind: :noul, question: "Is the customer asking for a human agent?",
        criteria: { true: "asks for a person; threatens to leave", false: "a routine request" },
        threshold: 0.7, siblings: { probability: :escalate_probability }
      )
      expect(Ticket.s1_fields[:department]).to eq(
        kind: :choice, question: "Which team?", scale: S1.scale(returns: nil, billing: nil),
        categories: { returns: "Refunds, exchanges", billing: "Charges, invoices. Not: an insurer asking about a claim" },
        as: :planned, given: :department_lens, siblings: { confidence: :department_confidence }
      )
      expect(Ticket.s1_fields[:severity]).to eq(
        kind: :score, question: "How severe is the issue?", scale: S1.scale("cosmetic", "degraded", "blocking"), levels: %w[cosmetic degraded blocking],
        criteria: ["no impact", "a workaround exists", "no workaround"],
        siblings: { expectation: :severity_expectation, index: :severity_index }
      )
      expect(Ticket.s1_fields[:priority]).to eq(kind: :score, question: "How urgent?", scale: S1.scale("can wait", "today", "now"),
                                                levels: ["can wait", "today", "now"], indexes: [10, 20, 30])
      expect(Ticket.s1_fields[:subtype]).to eq(kind: :choice, question: "What kind, within `department`?", scale: S1.scale(:subtypes, ordered: false),
                                               categories: :subtypes, after: [:department], dynamic: true)
      expect(Ticket.s1_fields[:grade]).to eq(kind: :score, question: "How good was the exchange?", scale: S1.scale("poor", "fair", "good"),
                                             levels: %w[poor fair good], indexes: [0, 1, 2])
      expect(Ticket.s1_fields[:severity][:scale].definitions)
        .to eq("cosmetic" => "no impact", "degraded" => "a workaround exists", "blocking" => "no workaround")
      expect(Ticket.s1_fields[:severity][:scale].name).to eq("Ticket#severity")
      expect(Ticket.s1_fields.keys.flat_map { |k| Ticket.s1_fields[k].keys }.uniq - S1::Measurable::Declarations::KEYS).to eq([])
    end

    it "keeps s1_instructions (s1_questions) and s1_kind beside it; s1_kind infers an undeclared column" do
      expect(Ticket.s1_instructions[:escalate]).to eq("Is the customer asking for a human agent?")
      expect(Ticket.s1_questions).to be(Ticket.s1_instructions)
      expect(%i[escalate department severity grade].map { |f| Ticket.s1_kind(f) }).to eq(%i[noul choice score score])
      expect(Ticket.s1_kind(:plan)).to eq(:choice)
      expect(Ticket.s1_kind(:severity_index)).to eq(:score)
      expect { Ticket.s1_kind(:created_at) }.to raise_error(ArgumentError, /cannot tell how to measure :created_at.*judges, chooses or scores/)
      expect(Ticket.grades).to eq("poor" => 0, "fair" => 1, "good" => 2)
    end

    it "inherits, and a subclass's declaration never leaks up" do
      sub = Class.new(Ticket) { judges :escalate, "Other?" }
      expect(sub.s1_fields[:escalate][:question]).to eq("Other?")
      expect(Ticket.s1_fields[:escalate][:question]).to eq("Is the customer asking for a human agent?")
      expect(sub.s1_fields.keys).to eq(Ticket.s1_fields.keys)
    end
  end

  describe "judges" do
    it "takes true: / false: as a String or Strings, criteria: as the wire form, and threshold:" do
      f = fields { judges :escalate, "q", true: "a", false: %w[b c], threshold: 0.6 }
      expect(f[:escalate]).to include(criteria: { true: "a", false: "b; c" }, threshold: 0.6)
      expect(fields { judges :escalate, "q", criteria: { true: "x" } }[:escalate][:criteria]).to eq(true: "x")
      expect(fields { judges :escalate, "q" }[:escalate]).to eq(kind: :noul, question: "q", siblings: { probability: :escalate_probability })
    end

    it "refuses an option it does not know, naming the ones it takes" do
      expect { fields { judges :escalate, "q", tru: "x" } }
        .to raise_error(ArgumentError, /judges :escalate has unknown option\(s\) \[:tru\]; it takes true:, false:, as:, given:, threshold:/)
    end

    it "is noul_field too" do
      expect(fields { noul_field :escalate, "q" }[:escalate][:kind]).to eq(:noul)
    end
  end

  describe "chooses" do
    it "takes bare labels, label => description, label => { is:, not: }, or categories: — and a plain enum's keys with none" do
      expect(fields { chooses :department, "q", :a, :b }[:department][:categories]).to eq(a: nil, b: nil)
      expect(fields { chooses :department, "q", a: "A", b: { is: "B", not: "C" } }[:department][:categories]).to eq(a: "A", b: "B. Not: C")
      expect(fields { chooses :department, "q", a: "A", b: { not: "C" } }[:department][:categories]).to eq(a: "A", b: "Not: C")
      expect(fields { chooses :department, "q", :a, b: "B" }[:department][:categories]).to eq(a: nil, b: "B")
      expect(fields { chooses :department, "q", categories: %i[a b] }[:department][:categories]).to eq(a: nil, b: nil)
      expect(fields { chooses :department, "q", categories: { a: "A", as: "a category named like an option" } }[:department])
        .to eq(kind: :choice, question: "q", scale: S1.scale(a: "A", as: "…"), categories: { a: "A", as: "a category named like an option" },
               siblings: { confidence: :department_confidence })
      expect(fields { chooses :department, "q", categories: ->(_r) { {} } }[:department]).to include(dynamic: true)
      expect(fields { chooses :department, "q", categories: :subtypes }[:department]).to include(categories: :subtypes, dynamic: true)
      expect { fields { chooses :department, "q", :a, categories: [:b] } }.to raise_error(ArgumentError, /give the categories once/)
      expect { fields { chooses :department, "q", a: { was: "x" } } }.to raise_error(ArgumentError, /a description is a String or \{ is:, not: \}/)
      expect { fields { chooses :department, "q", a: 1 } }.to raise_error(ArgumentError, /a description is a String/)
      expect(Class.new(Delivery) { chooses :note, "q" }.s1_fields[:note]).to eq(kind: :choice, question: "q", scale: S1.scale(fragile: nil, bulky: nil))
    end

    it "refuses threshold:, naming judges" do
      expect { fields { chooses :department, "q", :a, :b, threshold: 0.5 } }
        .to raise_error(ArgumentError, /: threshold: is a judge's collapse rule; :department is declared with chooses/)
      expect { fields { scores :severity, "q", :a, :b, threshold: 0.5 } }.to raise_error(ArgumentError, /declared with scores/)
    end
  end

  describe "scores" do
    it "takes positional labels, one { label => integer } Hash, label => description, levels:, indexes:" do
      expect(fields { scores :severity, "q", "a", "b" }[:severity])
        .to eq(kind: :score, question: "q", scale: S1.scale("a", "b"), levels: %w[a b],
               siblings: { expectation: :severity_expectation, index: :severity_index })
      expect(fields { scores :severity, "q", { "b" => 2, "a" => 1 } }[:severity]).to include(levels: %w[a b], indexes: [1, 2])
      expect(fields { scores :severity, "q", a: "A", b: "B" }[:severity]).to include(levels: %w[a b], criteria: %w[A B])
      expect(fields { scores :severity, "q", a: %w[A1 A2], b: "B" }[:severity][:criteria]).to eq(["A1; A2", "B"])
      expect(fields { scores :severity, "q", levels: %w[a b] }[:severity][:levels]).to eq(%w[a b])
      expect(fields { scores :severity, "q", levels: { a: 5, b: 9 } }[:severity]).to include(levels: %w[a b], indexes: [5, 9])
      expect(fields { scores :severity, "q", levels: { a: "A", b: "B" } }[:severity]).to include(levels: %w[a b], criteria: %w[A B])
      expect(fields { scores :severity, "q", a: "A", b: "B", indexes: { a: 1, b: 4 } }[:severity]).to include(indexes: [1, 4])
      expect(fields { scores :severity, "q", :a, :b, indexes: { a: 1, b: 4 } }[:severity]).to include(levels: %w[a b], indexes: [1, 4])
      expect(fields { scores :severity, "q", levels: -> { %w[a b] } }[:severity]).to include(dynamic: true)
      expect(fields { scores :severity, "q", levels: :subtypes }[:severity]).to include(levels: :subtypes, dynamic: true)
    end

    it "refuses ambiguity and bad indexes" do
      expect { fields { scores :severity, "q", "a", levels: %w[a b] } }.to raise_error(ArgumentError, /give the levels once/)
      expect { fields { scores :severity, "q", "a", b: "B" } }.to raise_error(ArgumentError, /give the levels once/)
      expect { fields { scores :severity, "q", { "a" => 1, "b" => 1 } } }.to raise_error(ArgumentError, /distinct integers/)
      expect { fields { scores :severity, "q", { "a" => 1, "b" => 2 }, indexes: { a: 1, b: 2 } } }.to raise_error(ArgumentError, /already gives the indexes/)
      expect { fields { scores :severity, "q", :a, :b, indexes: { a: 1 } } }.to raise_error(ArgumentError, /one integer per level/)
      expect { fields { scores :severity, "q", :a, :b, indexes: { a: 2, b: 1 } } }.to raise_error(ArgumentError, /increase with the levels/)
      expect { fields { scores :severity, "q", levels: -> { [] }, indexes: { a: 1 } } }.to raise_error(ArgumentError, /dynamic scale takes no indexes/)
      expect { fields { scores :severity, "q", levels: 3 } }.to raise_error(ArgumentError, /levels are a list/)
    end
  end

  describe "measured_field, the resolving form" do
    it "picks the kind from the declaration's shape, then the column" do
      resolved = Class.new(Ticket) do
        measured_field :escalate, "q"                                            # boolean → judges
        measured_field :escalate_probability, "q", true: "yes", false: "no"      # float, true:/false: → judges with criteria (the misread, fixed)
        measured_field :department, "q", a: "A", b: "B"                          # description hash → chooses
        measured_field :plan, "q", categories: %i[a b]                           # categories: → chooses
        measured_field :severity, "q", "a", "b"                                  # levels → scores
        measured_field :priority, "q", { "a" => 1, "b" => 2 }                    # { label => int } → scores with indexes
        measured_field :severity_index, "q", levels: %w[a b], indexes: { a: 1, b: 2 }
        measured_field :grade, "q"                                               # enum column → chooses
        measured_field :subtype, "q"                                             # string column, nothing → chooses (the enum's keys, or verify raises)
      end
      kinds = resolved.s1_fields.transform_values { |f| f[:kind] }
      expect(kinds).to eq(escalate: :noul, escalate_probability: :noul, department: :choice, plan: :choice, severity: :score,
                          priority: :score, severity_index: :score, grade: :choice, subtype: :choice)
      expect(resolved.s1_fields[:escalate_probability][:criteria]).to eq(true: "yes", false: "no")
      expect(resolved.s1_fields[:priority][:indexes]).to eq([1, 2])
      expect(Class.new(Delivery) { measured_field :priority_score, "q" }.s1_fields[:priority_score]).to eq(kind: :score, question: "q")
    end

    it "raises on a column whose type says nothing, naming the three macros" do
      expect { Class.new(Ticket) { measured_field :created_at, "q" } }
        .to raise_error(ArgumentError, / cannot tell how to measure :created_at \(column type :datetime\): declare it with judges, chooses or scores/)
    end

    it "is s1_field, measured_attribute and measurable_field" do
      %i[s1_field measured_attribute measurable_field].each { |old| expect(Ticket.method(old)).to eq(Ticket.method(:measured_field)) }
    end
  end

  describe "choice_enum and score_enum" do
    it "choice_enum declares the enum and the chooses; measured_enum / s1_enum are it; a bare name returns the descriptions" do
      klass = stub_const("Enumed", Class.new(Ticket) do
        choice_enum :plan, "Which plan?", gold: "the paid tier", free: { is: "no subscription", not: "a lapsed one" }, prefix: true, as: :planned
      end)
      expect(klass.plans).to eq("gold" => "gold", "free" => "free")
      expect(klass.new(plan: :gold)).to be_plan_gold
      expect(klass.s1_enum(:plan)).to eq(gold: "the paid tier", free: "no subscription. Not: a lapsed one")
      expect(klass.choice_enum(:plan)).to eq(klass.measured_enum(:plan))
      expect(klass.s1_fields[:plan]).to eq(kind: :choice, question: "Which plan?", as: :planned, scale: S1.scale(gold: nil, free: nil),
                                           categories: { gold: "the paid tier", free: "no subscription. Not: a lapsed one" })
      expect { klass.choice_enum(:colour) }.to raise_error(ArgumentError, /no choice_enum :colour/)
    end

    it "takes a structured question (a Hash), as mvp declares it" do
      klass = Class.new(Ticket) { choice_enum :plan, { question: "Which?", source: "`body`" }, gold: "g", free: "f" }
      expect(klass.s1_fields[:plan][:question]).to eq(question: "Which?", source: "`body`")
      stub_s1(plan: :free)
      expect(klass.new(body: "x").choice(:plan)).to eq(:free)
    end

    it "score_enum declares the enum with those integers and the scores with those indexes" do
      expect(Ticket.grades).to eq("poor" => 0, "fair" => 1, "good" => 2)
      expect(Ticket.s1_fields[:grade]).to include(levels: %w[poor fair good], indexes: [0, 1, 2])
      expect(Ticket.method(:measured_score_enum)).to eq(Ticket.method(:score_enum))
      expect { Class.new(Ticket) { score_enum :grade, "q", poor: "p" } }.to raise_error(ArgumentError, /label => Integer pairs/)
      klass = stub_const("Graded", Class.new(Ticket) { score_enum :grade, "q", bad: 5, ok: 7, prefix: true })
      expect(klass.s1_fields[:grade]).to include(levels: %w[bad ok], indexes: [5, 7])
      expect(klass.new(grade: :ok)).to be_grade_ok
      stub_s1(grade: 1)
      row = klass.create!(body: "x")
      row.update_measure(:grade)
      expect(row.reload.grade).to eq("ok")
      expect(row.grade_before_type_cast).to eq(7)
      expect(row.level(:grade)).to eq("ok")
      expect(row.level(:grade)).to be_a(S1::Level)
    end
  end

  describe "verify" do
    def bad(&) = Class.new(Ticket, &).s1_verify_fields!

    it "passes the spec models" do
      expect(Ticket.s1_verify_fields!).to eq(Ticket)
      expect(S1::Measurable.verify!).to include(Ticket, Delivery)
    end

    it "checks the kind against the column: judges on boolean / float / decimal, chooses on string / text / enum, scores never on an enum" do
      expect do
        bad do
          judges :department, "q"
        end
      end.to raise_error(ArgumentError, /:department is measured as noul but its column is string: declare it with chooses or scores/)
      expect { bad { chooses :escalate, "q", :a, :b } }.to raise_error(ArgumentError, /measured as choice but its column is boolean: declare it with judges/)
      expect do
        bad do
          chooses :priority, "q", :a, :b
        end
      end.to raise_error(ArgumentError, /measured as choice but its column is integer: declare it with scores with indexes/)
      expect { bad { scores :escalate, "q", :a, :b } }.to raise_error(ArgumentError, /measured as score but its column is boolean/)
      expect { bad { chooses :grade, "q", :poor, :fair } }.not_to raise_error
      expect { bad { scores :grade, "q", :a, :b } }.to raise_error(ArgumentError, /:grade has levels on an enum column that are not its keys/)
      expect { bad { scores :grade, "q", { "poor" => 0, "fair" => 1, "good" => 2 } } }.not_to raise_error
      expect { bad { scores :grade, "q", levels: -> { %w[a b] } } }.to raise_error(ArgumentError, /dynamic scale on an enum column/)
      expect { bad { chooses :grade, "q", categories: -> { %w[a b] } } }.to raise_error(ArgumentError, /dynamic scale on an enum column/)
      expect { bad { chooses :grade, "q", :poor, :best } }.to raise_error(ArgumentError, /categories \["best"\] are not in the enum/)
    end

    it "checks the scale: chooses need categories or an enum; scores need levels, and indexes on an integer column (else a warning)" do
      expect { bad { chooses :department, "q" } }.to raise_error(ArgumentError, /:department is a chooses with no categories: give them, or declare the enum/)
      expect { bad { scores :priority, "q", levels: -> { %w[a b] } } }.to raise_error(ArgumentError, /dynamic score on an integer column/)
      log = StringIO.new
      S1.config.logger = Logger.new(log)
      bad { scores :priority, "q", :a, :b }
      expect(log.string).to include("positional levels").and include("explicit indexes")
      expect { bad { scores :severity, "q", levels: :subtypes, siblings: false } }.not_to raise_error # severity_index would follow position
    end

    it "checks the options: threshold on judges, as: a declared form, given: a method, after: a field without a cycle, siblings that fit" do
      expect { bad { judges :escalate, "q", as: :nope } }.to raise_error(ArgumentError, /:escalate as: :nope is not a declared form/)
      expect { bad { judges :escalate, "q", as: :default } }.not_to raise_error
      expect { bad { judges :escalate, "q", given: :nope } }.to raise_error(ArgumentError, /given: :nope names no method/)
      expect { bad { judges :escalate, "q", given: -> { {} } } }.not_to raise_error
      expect { bad { judges :escalate, "q", given: 3 } }.to raise_error(ArgumentError, /given: is a Proc, a method name or a Hash/)
      expect { bad { judges :escalate, "q", after: :nope } }.to raise_error(ArgumentError, /after: :nope is not a measured field/)
      expect { bad { judges :escalate, "q", after: :department } }.not_to raise_error
      expect do
        bad do
          judges :escalate, "q", after: :severity
          scores :severity, "q", :a, :b, after: :escalate
        end
      end.to raise_error(ArgumentError, /after: cycle :escalate → :severity → :escalate/)
      expect { bad { judges :escalate, "q", siblings: { probability: :nope } } }.to raise_error(ArgumentError, /sibling :nope is not a column/)
      expect do
        bad do
          judges :escalate, "q", siblings: { probability: :priority }
        end
      end.to raise_error(ArgumentError, /sibling :priority is integer; probability needs float/)
      expect do
        bad do
          judges :escalate, "q", siblings: { expectation: :escalate_probability }
        end
      end.to raise_error(ArgumentError, /has no expectation: it is a noul/)
      expect do
        bad do
          judges :escalate, "q", siblings: { mass: :escalate_probability }
        end
      end.to raise_error(ArgumentError, /sibling :mass is not a part of a distribution/)
      expect do
        bad do
          judges :escalate, "q", siblings: false
          scores :subtype, "q", :a, :b, siblings: { index: :priority, expectation: :escalate_probability }
        end
      end.not_to raise_error
    end
  end
end
