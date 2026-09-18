# frozen_string_literal: true

# The README's example, run: two models, an association, a validation, a callback,
# a job, a webhook-shaped create, a stream, and the collapse happening in SQL.
RSpec.describe "lost and found" do
  before(:all) do
    ActiveRecord::Schema.define do
      create_table :items do |t|
        t.text :description
        t.string :line
        t.string :category
        t.boolean :claimed, default: false
        t.timestamps
      end
      create_table :claims do |t|
        t.references :item
        t.text :story
        t.float :plausible
        t.float :match
        t.timestamps
      end
    end
  end

  after(:all) do
    %i[claims items].each { |t| ActiveRecord::Base.connection.drop_table(t) }
    S1::Measurable.models.delete_if { |m| %w[items claims].include?(m.table_name) }
  end

  before do
    stub_s1 do |req|
      s = req.state
      case req.questions.keys
      when [:category] then { category: s[:found].to_s.include?("umbrella") ? :umbrella : :other }
      when %i[plausible match]
        { plausible: s[:story].to_s.size > 10 ? 0.9 : 0.1,
          match: s[:story].to_s.include?("umbrella") && s[:item][:found].to_s.include?("umbrella") ? 0.93 : 0.08 }
      when [:noul]
        if s.key?(:note) # the given(...) scope: judged against a policy
          { noul: s[:this][:found].to_s.include?("umbrella") ? 0.9 : 0.1 }
        else # same_as?: { this:, other: } — the text on one side, the item's form on the other
          { noul: s.values_at(:this, :other).map(&:to_s).all? { |side| side.include?("umbrella") } ? 0.9 : 0.1 }
        end
      end
    end
  end

  let(:models) do
    item_class = Class.new(ActiveRecord::Base) do
      self.table_name = "items"
      include S1::Measurable

      measurable_as { { found: description, where: line, since: created_at&.strftime("%Y-%m-%d") } }
      choice_enum :category, "What is it?", umbrella: "an umbrella", phone: "a phone", bag: "a bag or case", other: "anything else",
                                            measure_on: :create
      scope :unclaimed, -> { where(claimed: false) }
    end
    stub_const("Item", item_class)
    claim_class = Class.new(ActiveRecord::Base) do
      self.table_name = "claims"
      include S1::Measurable

      belongs_to :item, class_name: "Item"
      measurable_as { { story: story, item: item } }
      judges :plausible, "Is `story` a plausible account of losing the `item`?", measure_on: :validation, if: :will_save_change_to_story?
      judges :match,     "Is `story` describing the same object as `item`?", measure_on: :validation, if: :will_save_change_to_story?
      validates :plausible, numericality: { greater_than: 0.5, message: "doesn't sound like this item" }
      scope :likely, -> { where(match: 0.8..) }
    end
    stub_const("Claim", claim_class)
    [item_class, claim_class]
  end

  it "runs end to end" do
    item_class, claim_class = models
    umbrella = item_class.create!(description: "black umbrella, wooden handle", line: "8:15 to Leeds")
    perform_enqueued_jobs
    expect(umbrella.reload).to be_umbrella # the job collapsed :category

    text = "left my black umbrella on the 8:15 this morning, wooden handle"
    found = item_class.unclaimed.where_same_as(text, concurrency: 2).first # the relation's same_as?; grep(ψ text) is the same, sequential
    expect(found).to eq(umbrella)

    claim = claim_class.create!(item: umbrella, story: text)
    expect(claim.match).to eq(0.93) # float columns: the probabilities, kept — one call for both
    expect(claim.plausible).to eq(0.9)
    expect(claim_class.likely).to include(claim) # the collapse, in SQL, later

    bad = claim_class.new(item: umbrella, story: "mine")
    expect(bad).not_to be_valid
    expect(bad.errors[:plausible]).to eq(["doesn't sound like this item"]) # a plain Rails validation on the measured column

    sock = item_class.create!(description: "one grey sock", line: "8:15 to Leeds")
    item_class.unclaimed
              .given(note: "we keep anything with an owner's name or over £20")
              .where_is_not("worth keeping", concurrency: 2)
              .destroy_all # a where_ returns a relation
    expect(item_class.exists?(sock.id)).to be(false)
    expect(item_class.exists?(umbrella.id)).to be(true)
  end
end
