# frozen_string_literal: true

namespace :s1 do
  desc "Remeasure Model.stale(column) in batches — rake s1:remeasure[PhoneCall,is_lead]; BATCH=100 CONCURRENCY=1"
  task :remeasure, %i[model column] => :environment do |_task, args|
    model = args.fetch(:model) { abort "usage: rake s1:remeasure[Model,column]" }.constantize
    column = args.fetch(:column) { abort "usage: rake s1:remeasure[Model,column]" }.to_sym
    stale = model.stale(column)
    total = stale.count
    puts "#{model}.stale(#{column.inspect}): #{total} row(s)"
    done = 0
    stale.in_batches(of: Integer(ENV.fetch("BATCH", 100))) do |batch|
      done += batch.update_measure_all(column, concurrency: Integer(ENV.fetch("CONCURRENCY", 1))).size
      puts "  #{done}/#{total}"
    end
  end
end
