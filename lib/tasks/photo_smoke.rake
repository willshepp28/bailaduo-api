require 'zlib'
require 'stringio'

namespace :photos do
  desc 'Verify one real disposable BailaDuo upload/profile and delete only that image (development/test only)'
  task smoke: :environment do
    abort 'photos:smoke requires a disposable development/test database' unless Rails.env.development? || Rails.env.test?
    database = ActiveRecord::Base.connection_db_config.configuration_hash
    local_host = database[:host].presence || 'localhost'
    unless %w[localhost 127.0.0.1 ::1].include?(local_host) && database[:database].to_s.match?(/\Abailaduo.*(?:development|test)\z/)
      abort 'photos:smoke refuses remote or non-disposable database configuration'
    end
    provider = CloudflareImages.new
    abort 'Media environment must match the local Rails environment for this smoke check' unless provider.environment == Rails.env
    user = nil
    upload = nil
    begin
      # Generate a tiny PNG in memory, without adding image fixtures or disk storage.
      chunk = lambda { |name, data| [data.bytesize].pack('N') + name + data + [Zlib.crc32(name + data)].pack('N') }
      png = "\x89PNG\r\n\x1A\n".b + chunk.call('IHDR', [1, 1, 8, 2, 0, 0, 0].pack('NNCCCCC')) +
            chunk.call('IDAT', Zlib::Deflate.deflate("\x00\xA0\x30\x50".b)) + chunk.call('IEND', ''.b)
      user = User.create!(email: "api003-smoke-#{SecureRandom.uuid}@example.test", password: SecureRandom.hex(16))
      upload, url = PhotoUpload.issue_for!(user, content_type: 'image/png', byte_size: png.bytesize, provider: provider)
      uri = URI.parse(url)
      request = Net::HTTP::Post.new(uri.request_uri)
      request.set_form([['file', StringIO.new(png), { filename: 'bailaduo-disposable-smoke.png', content_type: 'image/png' }]], 'multipart/form-data')
      # The upload host receives NO Rails credentials and NO Cloudflare API token.
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 30) { |http| http.request(request) }
      raise CloudflareImages::Error, 'Direct upload failed' unless response.is_a?(Net::HTTPSuccess)
      upload.verify!(provider: provider)
      profile = user.create_profile!(display_name: 'Disposable photo verification', age: 28, city: 'API003 QA', dance_styles: ['bachata'],
        experience_level: 'beginner', availability: 'Weekends', primary_photo_upload: upload, primary_photo_url: upload.delivery_url)
      raise 'Profile photo was not persisted' unless profile.reload.primary_photo_url == upload.reload.delivery_url
      puts 'Real Cloudflare upload, provider verification, and profile persistence passed.'
    ensure
      if user
        user.profile&.destroy!
        upload ||= PhotoUpload.where(user: user).first
        if upload
          upload.delete_unreferenced!(provider: provider)
          upload.destroy!
        end
        user.destroy!
        puts 'Only the designated disposable BailaDuo photo and local smoke account were removed.'
      end
    end
  rescue CloudflareImages::Error => error
    abort "Photo smoke verification incomplete: #{error.message}. Retained owned records can be retried via photos:cleanup."
  end
end
