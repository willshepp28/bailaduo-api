namespace :dev do
  desc 'Create/preserve 15 fictional Playa dancers in the confirmed local development database'
  task seed_playa: :environment do
    result = Development::PlayaSeeds.new.run
    puts "Playa cohort: #{result[:users]} users / #{result[:profiles]} profiles; created #{result[:created_users]} users / #{result[:created_profiles]} profiles."
    puts "Private credentials: #{result[:credentials_file]} (mode 0600; do not share in GitHub/logs)."
    portraits = Development::PlayaPortraits.new.run
    puts "Portraits: #{portraits[:attached]} attached; #{portraits[:preserved]} existing photos preserved."
  rescue Development::PlayaSeeds::Refused, CloudflareImages::Error => error
    abort error.message
  end

  desc 'Replace only the existing cohort numbered fixtures with supplied owned development portraits'
  task refresh_playa_portraits: :environment do
    result = Development::PlayaPortraits.new.run
    puts "Portraits: #{result[:attached]} attached; #{result[:preserved]} existing photos preserved."
  rescue Development::PlayaSeeds::Refused, CloudflareImages::Error => error
    abort error.message
  end
end
