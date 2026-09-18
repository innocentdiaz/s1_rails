# frozen_string_literal: true

module S1
  # Rails defaults, applied before config/initializers so an initializer can
  # still override them:
  #   - logger: Rails.logger
  #   - every completed measure emits "ask.s1" (payload: result, request) for
  #     cost ledgers and telemetry; request.metadata is the caller's metadata: label:
  #       ActiveSupport::Notifications.subscribe("ask.s1") do |event|
  #         result, request = event.payload.values_at(:result, :request)
  #         Ledger.record(owner: request.options[:owner], name: request.metadata[:call_type], model: result.model, **result.usage)
  #       end
  #   - rake s1:remeasure[Model,column] (lib/tasks/s1.rake)
  class Railtie < ::Rails::Railtie
    initializer "s1.defaults", before: :load_config_initializers do
      S1.config.logger ||= ::Rails.logger
      S1.on_result do |result, request|
        ActiveSupport::Notifications.instrument("ask.s1", result: result, request: request)
      end
    end

    rake_tasks { load File.expand_path("../tasks/s1.rake", __dir__) }

    # Measured fields vs the schema, once the models are loaded (eager_load: production).
    config.after_initialize do |app|
      S1::Measurable.verify! if app.config.eager_load
    end
  end
end
