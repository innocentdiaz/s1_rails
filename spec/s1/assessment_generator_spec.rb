# frozen_string_literal: true

require "rails/generators"
require "generators/s1/assessment/assessment_generator"
require "tmpdir"

RSpec.describe S1::Generators::AssessmentGenerator do
  around { |example| Dir.mktmpdir { |root| @root = root and example.run } }

  def generate(*args) = described_class.start([*args, "--quiet"], destination_root: @root)
  def written(path) = File.read(File.join(@root, path))

  it "is what rails generate s1:assessment finds" do
    expect(Rails::Generators.find_by_namespace("s1:assessment")).to be(described_class)
  end

  it "writes the assessment, and a spec when the app has spec/" do
    FileUtils.mkdir_p(File.join(@root, "spec"))
    generate("refund_eligibility")

    source = written("app/assessments/refund_eligibility_assessment.rb")
    expect(source).to include("class RefundEligibilityAssessment", 'metadata: { call_type: "refund_eligibility" }')
    expect(written("spec/assessments/refund_eligibility_assessment_spec.rb")).to include("RSpec.describe RefundEligibilityAssessment")
  end

  it "writes a test instead when the app has no spec/" do
    generate("refund_eligibility")
    expect(written("test/assessments/refund_eligibility_assessment_test.rb")).to include("class RefundEligibilityAssessmentTest")
  end

  it "nests a namespaced name, and labels it with the namespace" do
    generate("billing/refund_eligibility")
    expect(written("app/assessments/billing/refund_eligibility_assessment.rb"))
      .to include("class Billing::RefundEligibilityAssessment", 'metadata: { call_type: "billing/refund_eligibility" }')
  end

  it "generates a class that measures one labelled question per item of its standard" do
    generate("refund_eligibility")
    Object.class_eval(written("app/assessments/refund_eligibility_assessment.rb"))
    assessment = Class.new(RefundEligibilityAssessment) { define_method(:standard) { ["has the receipt", "is unopened"] } }

    requests = []
    S1.config.provider = S1::Providers::Stub.new(q0: :yes, q1: :unknown)
    S1.on_result { |_result, request| requests << request }
    result = assessment.call(PhoneCall.create!(transcript: "I have the receipt"))

    expect(result.verdicts).to eq("has the receipt" => :yes, "is unopened" => :unknown)
    expect(requests.map(&:metadata)).to eq([{ call_type: "refund_eligibility" }])
  ensure
    Object.send(:remove_const, :RefundEligibilityAssessment) if Object.const_defined?(:RefundEligibilityAssessment)
  end
end
