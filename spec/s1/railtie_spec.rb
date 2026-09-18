# frozen_string_literal: true

require "rails"
require "rake"
require "s1/railtie"

RSpec.describe S1::Railtie do
  before(:all) do
    app = Class.new(Rails::Application) do
      config.eager_load = false
      config.logger = Logger.new(nil)
      config.active_support.to_time_preserves_timezone = :zone
    end
    app.initialize!
  end

  # The suite resets config per example, so re-apply what the boot initializer did.
  before do
    described_class.initializers.each { |i| i.run(Rails.application) }
    S1.config.provider = S1::Providers::Stub.new(noul: 0.9)
  end

  it "defaults the logger" do
    expect(S1.config.logger).to eq(Rails.logger)
  end

  it "loads rake s1:remeasure with the app's tasks" do
    Rails.application.load_tasks
    expect(Rake::Task.task_defined?("s1:remeasure")).to be(true)
    expect(Rake::Task["s1:remeasure"].arg_names).to eq(%i[model column])
  end

  it "instruments every call as ask.s1" do
    events = []
    ActiveSupport::Notifications.subscribed(->(event) { events << event.payload }, "ask.s1") do
      S1::State.new("x", owner: :me).judge?("q?")
    end
    expect(events.size).to eq(1)
    expect(events.first[:request].options[:owner]).to eq(:me)
    expect(events.first[:result].model).to eq("stub")
  end
end
