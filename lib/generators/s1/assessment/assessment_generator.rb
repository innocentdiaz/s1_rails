# frozen_string_literal: true

require "rails/generators/named_base"

module S1
  module Generators
    # rails generate s1:assessment refund_eligibility
    #   app/assessments/refund_eligibility_assessment.rb
    #   spec/assessments/refund_eligibility_assessment_spec.rb (test/assessments/…_test.rb without spec/)
    class AssessmentGenerator < Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)
      desc "An s1 assessment: a measurement whose set of questions is built from data at run time."

      def create_assessment
        template "assessment.rb.tt", File.join("app/assessments", class_path, "#{file_name}_assessment.rb")
      end

      def create_test
        if File.directory?(File.join(destination_root, "spec"))
          template "assessment_spec.rb.tt", File.join("spec/assessments", class_path, "#{file_name}_assessment_spec.rb")
        else
          template "assessment_test.rb.tt", File.join("test/assessments", class_path, "#{file_name}_assessment_test.rb")
        end
      end
    end
  end
end
