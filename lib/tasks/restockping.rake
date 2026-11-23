# frozen_string_literal: true

namespace :restockping do
  desc "Re-enqueue restock fan-outs and emails whose jobs were lost (run from cron)"
  task requeue_stalled: :environment do
    RequeueStalledNotificationsJob.perform_now
  end
end
