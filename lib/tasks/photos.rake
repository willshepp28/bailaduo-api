namespace :photos do
  desc 'Delete at most 50 expired, abandoned or superseded owned BailaDuo photos'
  task cleanup: :environment do
    puts PhotoUpload.cleanup!.to_json
  end
end
