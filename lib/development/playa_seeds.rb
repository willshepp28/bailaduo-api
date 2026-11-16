require 'json'
require 'tempfile'

module Development
  class PlayaSeeds
    class Refused < StandardError; end

    DATABASE = 'bailaduo_api_integration_development'.freeze
    COHORT = 'bailaduo-playa-local-v1'.freeze
    MANIFEST = Rails.root.join('tmp/playa-test-users.json')
    LOCAL_HOSTS = [nil, '', 'localhost', '127.0.0.1', '::1', '/tmp', '/var/run/postgresql'].freeze
    # Fictional adults; the numbered placeholder images explicitly identify test data.
    DANCERS = [
      ['Lucia Moreno', 24, 'beginner', ['bachata'], 'Tuesday and Thursday evenings', 'Practice basic timing and relaxed turns.'],
      ['Mateo Rivas', 28, 'beginner', %w[bachata salsa], 'Saturday mornings', 'Build confidence before my first social.'],
      ['Elena Solis', 22, 'beginner', ['bachata'], 'Monday and Wednesday after 6 pm', 'Improve footwork one song at a time.'],
      ['Diego Navarro', 31, 'beginner', %w[bachata kizomba], 'Sunday afternoons', 'Work on clear leads and musical timing.'],
      ['Camila Vega', 26, 'beginner', %w[bachata salsa], 'Friday evenings', 'Review class combinations at an easy pace.'],
      ['Andres Luna', 35, 'beginner', ['bachata'], 'Weekdays before 9 am', 'Find a regular weekly basics practice.'],
      ['Sofia Marquez', 29, 'intermediate', %w[bachata salsa], 'Tuesday evenings and Sunday mornings', 'Explore musical breaks and smooth transitions.'],
      ['Rafael Duarte', 33, 'intermediate', %w[bachata zouk], 'Wednesday and Friday evenings', 'Improve connection and balance in turns.'],
      ['Valeria Costa', 27, 'intermediate', %w[bachata kizomba], 'Saturday afternoons', 'Practice body movement with a patient partner.'],
      ['Nicolas Paredes', 38, 'intermediate', %w[bachata salsa], 'Monday and Thursday evenings', 'Sharpen partnerwork and listening skills.'],
      ['Marina Salcedo', 32, 'intermediate', %w[bachata zouk], 'Sunday mornings', 'Develop cleaner footwork and phrasing.'],
      ['Tomas Beltran', 41, 'intermediate', ['bachata'], 'Weekday lunch breaks', 'Keep a consistent short practice routine.'],
      ['Isabel Fuentes', 36, 'advanced', %w[bachata salsa], 'Tuesday and Saturday evenings', 'Refine musical interpretation and technique.'],
      ['Gabriel Lozano', 45, 'advanced', %w[bachata kizomba], 'Wednesday afternoons', 'Exchange feedback on connection and precision.'],
      ['Daniela Montes', 48, 'advanced', %w[bachata salsa zouk], 'Weekend mornings', 'Explore creative combinations with safe technique.']
    ].freeze

    def initialize(manifest_path: MANIFEST)
      @path = Pathname.new(manifest_path)
    end

    def run
      verify_database!
      verify_private_path!
      # One file lock serializes local runs, including initial manifest creation.
      File.open("#{@path}.lock", File::RDWR | File::CREAT | File::NOFOLLOW, 0o600) do |lock|
        lock.chmod(0o600)
        lock.flock(File::LOCK_EX)
        manifest = read_manifest
        created_users = 0
        created_profiles = 0
        ActiveRecord::Base.logger.silence do
          User.transaction do
            # Also serialize runs using a different manifest path against this database.
            User.connection.execute('SELECT pg_advisory_xact_lock(916001)')
            entries = manifest ? manifest.fetch('users') : new_entries
            entries.each_with_index do |entry, index|
              user = owned_user(entry)
              unless user
                user = User.create!(email: entry.fetch('email'), password: entry.fetch('password'))
                entry['user_id'] = user.id
                entry['user_created_at'] = user.created_at.iso8601(6)
                created_users += 1
              end
              unless user.profile
                user.create_profile!(profile_attributes(index))
                created_profiles += 1
              end
              entry['profile_id'] = user.profile.id
              entry['display_name'] = user.profile.display_name
            end
            write_manifest('cohort' => COHORT, 'database' => DATABASE, 'users' => entries)
          end
        end
        { users: 15, profiles: 15, created_users: created_users, created_profiles: created_profiles, credentials_file: @path.to_s }
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique
      raise Refused, 'Seed validation/collision failed; database changes rolled back. Existing passwords were not reset.'
    end

    def verify_database!
      raise Refused, 'Playa seeds require Rails development' unless Rails.env.development?
      config = User.connection_db_config.configuration_hash
      unless config[:adapter] == 'postgresql' && config[:database] == DATABASE && LOCAL_HOSTS.include?(config[:host]) &&
             (config[:port].nil? || config[:port].to_s == '5432')
        raise Refused, 'Playa seeds require the dedicated local BailaDuo database on port 5432'
      end
      # Inspect libpq's effective connection too: PGHOST/PGSERVICE can override defaults.
      connection = User.connection
      raw = connection.raw_connection
      actual = connection.select_one('SELECT current_database() AS database, inet_server_addr()::text AS address, current_setting(\'port\') AS port')
      unless raw.db == DATABASE && LOCAL_HOSTS.include?(raw.host) && raw.port.to_s == '5432' &&
             actual['database'] == DATABASE && [nil, '127.0.0.1', '::1'].include?(actual['address']) && actual['port'] == '5432'
        raise Refused, 'Resolved PostgreSQL connection is not the confirmed local development database'
      end
    end

    private

    def verify_private_path!
      unless @path.dirname == Rails.root.join('tmp') && system('git', 'check-ignore', '-q', '--', @path.to_s)
        raise Refused, 'Credentials must use a git-ignored file directly inside Rails tmp/'
      end
      if @path.symlink? || (@path.exist? && !@path.file?)
        raise Refused, 'Credentials manifest must be a regular private file'
      end
    end

    def read_manifest
      return unless @path.exist?
      @path.chmod(0o600)
      data = JSON.parse(@path.read)
      entries = data['users']
      valid = data['cohort'] == COHORT && data['database'] == DATABASE && entries.is_a?(Array) && entries.size == 15 &&
              entries.map { |entry| entry['email'] } == emails && entries.all? do |entry|
                entry['password'].is_a?(String) && entry['password'].bytesize.between?(8, 72) &&
                  entry['user_id'].is_a?(Integer) && entry['user_id'].positive? && entry['user_created_at'].is_a?(String)
              end
      raise Refused, 'Credentials manifest is invalid; restore its private backup. No passwords were reset.' unless valid
      data
    rescue JSON::ParserError, TypeError, NoMethodError
      raise Refused, 'Credentials manifest is corrupt; restore its private backup. No passwords were reset.'
    end

    def emails
      (1..15).map { |number| format('playa%02d@bailaduo.test', number) }
    end

    def new_entries
      if User.where(email: emails).exists? || User.where(uid: emails, provider: 'email').exists?
        raise Refused, 'Seed email collision without an ownership manifest; refusing to adopt accounts or reset passwords'
      end
      emails.map { |email| { 'email' => email, 'password' => SecureRandom.urlsafe_base64(24) } }
    end

    def owned_user(entry)
      return unless entry['user_id']
      user = User.find_by(id: entry.fetch('user_id'))
      if user && user.email == entry['email'] && user.uid == entry['email'] && user.provider == 'email' &&
         user.created_at.iso8601(6) == entry['user_created_at']
        return user
      end
      # Missing owned rows may be recreated; any ambiguous replacement must be reviewed.
      if user || User.where(email: entry['email']).exists? || User.where(uid: entry['email'], provider: 'email').exists?
        raise Refused, 'Seed identity collision; refusing to overwrite an account'
      end
      nil
    end

    def profile_attributes(index)
      name, age, experience, styles, availability, goal = DANCERS.fetch(index)
      { display_name: name, age: age, city: 'Playa del Carmen', dance_styles: styles, experience_level: experience,
        availability: availability, bio: "Fictional local test dancer. #{goal}",
        primary_photo_url: format('https://placehold.co/400x400/png?text=Playa+%02d', index + 1) }
    end

    def write_manifest(data)
      # Write before committing: a disk failure rolls back new accounts rather than losing passwords.
      Tempfile.create(['.playa-credentials-', '.json'], @path.dirname) do |file|
        file.chmod(0o600)
        file.write(JSON.pretty_generate(data) + "\n")
        file.flush
        file.fsync
        File.rename(file.path, @path)
      end
    end
  end
end
