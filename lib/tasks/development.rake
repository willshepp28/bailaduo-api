namespace :dev do
  desc 'Create/preserve 15 fictional Playa dancers in the confirmed local development database'
  task seed_playa: :environment do
    result = Development::PlayaSeeds.new.run
    puts "Playa cohort: #{result[:users]} users / #{result[:profiles]} profiles; created #{result[:created_users]} users / #{result[:created_profiles]} profiles."
    puts "Private credentials: #{result[:credentials_file]} (mode 0600; do not share in GitHub/logs)."
  rescue Development::PlayaSeeds::Refused => error
    abort error.message
  end
end
