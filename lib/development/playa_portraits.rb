require 'digest'
require 'net/http'

module Development
  class PlayaPortraits
    ASSETS = Rails.root.join('test/fixtures/files/playa_portraits')
    PROGRESS = Rails.root.join('tmp/playa-portrait-progress.json')

    def initialize(seed: PlayaSeeds.new, api: LocalApi.new, progress_path: PROGRESS)
      @seed, @api, @progress_path = seed, api, Pathname.new(progress_path)
    end

    def run
      entries = @seed.existing_cohort!
      provider = CloudflareImages.new
      refuse!('Portraits require the configured development media environment') unless provider.environment == 'development'
      portraits = validated_portraits(entries)
      unless @progress_path.dirname == Rails.root.join('tmp') && !@progress_path.symlink? &&
             system('git', 'check-ignore', '-q', '--', @progress_path.to_s)
        refuse!('Portrait progress must be a regular ignored file in Rails tmp/')
      end
      File.open("#{@progress_path}.lock", File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        progress = read_progress
        counts = { attached: 0, preserved: 0 }
        ActiveRecord::Base.logger.silence do
          entries.zip(portraits).each_with_index do |(entry, portrait), index|
            user = User.find(entry.fetch('user_id'))
            placeholder = format('https://placehold.co/400x400/png?text=Playa+%02d', index + 1)
            unless numbered_fixture?(user.profile, placeholder)
              counts[:preserved] += 1
              next
            end
            @api.with_session(entry) do
              own = @api.json(:get, '/api/profile').fetch('data')
              unless own['id'] == entry['profile_id'] && own['primary_photo_url'] == placeholder
                refuse!('Running API profile does not match the confirmed local cohort')
              end
              checkpoint = progress[entry.fetch('email')]
              if checkpoint
                unless checkpoint['sha256'] == portrait['sha256'] && checkpoint['user_id'] == user.id
                  refuse!('Portrait progress identity/checksum mismatch; review the private progress file')
                end
                upload = user.photo_uploads.find(checkpoint.fetch('upload_id'))
                provider.assert_owned!(upload)
              else
                issued = @api.json(:post, '/api/photo_uploads', { photo_upload: {
                  content_type: 'image/jpeg', byte_size: portrait.fetch('bytes')
                } }, expected: 201).fetch('data')
                # Confirm the local row/environment before sending any portrait bytes.
                upload = user.photo_uploads.find(issued.fetch('id'))
                provider.assert_owned!(upload)
                progress[entry.fetch('email')] = { 'user_id' => user.id, 'upload_id' => upload.id, 'sha256' => portrait.fetch('sha256') }
                write_progress(progress)
                @api.upload(issued.fetch('upload_url'), ASSETS.join(portrait.fetch('file')))
              end
              @api.json(:post, "/api/photo_uploads/#{upload.id}/complete")
              if attach_if_unchanged(user, entry.fetch('profile_id'), placeholder, upload, provider)
                counts[:attached] += 1
              else
                counts[:preserved] += 1
              end
            end
          end
        end
        counts
      end
    rescue KeyError, JSON::ParserError, TypeError, ActiveRecord::RecordNotFound
      refuse!('Portrait fixture/progress identity is invalid; no account/password reset was attempted')
    end

    private

    def validated_portraits(entries)
      manifest = JSON.parse(ASSETS.join('manifest.json').read)
      portraits = manifest.fetch('portraits')
      unless manifest['cohort'] == PlayaSeeds::COHORT && portraits.map { |portrait| portrait['email'] } == entries.map { |entry| entry['email'] }
        refuse!('Portrait manifest does not match the seed cohort')
      end
      portraits.each_with_index do |portrait, index|
        refuse!('Unexpected portrait filename') unless portrait['file'] == format('playa%02d.jpg', index + 1)
        path = ASSETS.join(portrait.fetch('file'))
        unless path.size == portrait['bytes'] && path.size.between?(1, CloudflareImages::MAX_BYTES) &&
               Digest::SHA256.file(path).hexdigest == portrait['sha256']
          refuse!('Supplied portrait checksum/size mismatch')
        end
      end
      refuse!('Portraits must be distinct') unless portraits.map { |portrait| portrait['sha256'] }.uniq.size == 15
      portraits
    end

    def numbered_fixture?(profile, placeholder)
      profile.primary_photo_upload_id.nil? && profile.primary_photo_url == placeholder
    end

    def attach_if_unchanged(user, profile_id, placeholder, upload, provider)
      user.with_lock do
        profile = user.profile.reload
        refuse!('Seed profile identity changed during refresh') unless profile.id == profile_id
        return false unless numbered_fixture?(profile, placeholder)
        upload.with_lock do
          upload.verify!(provider: provider)
          profile.update!(primary_photo_upload: upload, primary_photo_url: upload.delivery_url)
          upload.update!(status: 'attached')
        end
      end
      true
    end

    def read_progress
      return {} unless @progress_path.exist?
      @progress_path.chmod(0o600)
      data = JSON.parse(@progress_path.read)
      unless data['cohort'] == PlayaSeeds::COHORT && data['database'] == PlayaSeeds::DATABASE && data['uploads'].is_a?(Hash)
        refuse!('Portrait progress belongs to a different cohort/database')
      end
      data.fetch('uploads')
    end

    def write_progress(progress)
      Tempfile.create(['.playa-portrait-', '.json'], @progress_path.dirname) do |file|
        file.chmod(0o600)
        file.write(JSON.pretty_generate(cohort: PlayaSeeds::COHORT, database: PlayaSeeds::DATABASE, uploads: progress) + "\n")
        file.flush
        file.fsync
        File.rename(file.path, @progress_path)
      end
    end

    def refuse!(message)
      raise PlayaSeeds::Refused, message
    end

    # Fixed local API origin; provider requests never receive Rails credentials.
    class LocalApi
      def with_session(entry)
        result, response = request(:post, '/api/auth/sign_in', { email: entry.fetch('email'), password: entry.fetch('password') })
        @headers = %w[access-token client uid].to_h { |key| [key, response[key] || raise(PlayaSeeds::Refused, 'Missing API authentication header')] }
        unless result.dig('data', 'id') == entry['user_id'] && User.find(entry['user_id']).reload.tokens.key?(@headers.fetch('client'))
          raise PlayaSeeds::Refused, 'Running API account/database identity mismatch'
        end
        yield
      ensure
        json(:delete, '/api/auth/sign_out') if @headers
        @headers = nil
      end

      def json(method, path, body = nil, expected: 200)
        request(method, path, body, expected: expected).first
      end

      def upload(url, path)
        uri = URI.parse(url)
        unless uri.is_a?(URI::HTTPS) && uri.host == 'upload.imagedelivery.net' && uri.userinfo.nil?
          raise PlayaSeeds::Refused, 'Invalid provider upload destination'
        end
        request = Net::HTTP::Post.new(uri.request_uri)
        File.open(path, 'rb') do |file|
          request.set_form([['file', file, { filename: path.basename.to_s, content_type: 'image/jpeg' }]], 'multipart/form-data')
          response = transport(uri, request)
          raise PlayaSeeds::Refused, 'Portrait upload failed; retry the saved upload confirmation before issuing another' unless response.is_a?(Net::HTTPSuccess)
        end
      rescue URI::InvalidURIError
        raise PlayaSeeds::Refused, 'Invalid provider upload destination'
      end

      private

      def request(method, path, body, expected: 200)
        uri = URI("http://localhost:3100#{path}")
        request = Net::HTTP.const_get(method.to_s.capitalize).new(uri.request_uri)
        request['Content-Type'] = 'application/json'
        @headers&.each { |key, value| request[key] = value }
        request.body = JSON.generate(body) if body
        response = transport(uri, request)
        unless response.code.to_i == expected
          raise PlayaSeeds::Refused, "Local API #{method.to_s.upcase} #{path} returned #{response.code}; response/credentials withheld"
        end
        [JSON.parse(response.body), response]
      end

      def transport(uri, request)
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 5, read_timeout: 30, write_timeout: 30) do |http|
          http.request(request)
        end
      rescue Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError, Net::ProtocolError
        raise PlayaSeeds::Refused, 'Local API/provider unavailable; credentials and upload URL withheld'
      end
    end
  end
end
