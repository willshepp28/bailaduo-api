require 'test_helper'
require 'minitest/mock'

class Development::PlayaSeedsTest < ActiveSupport::TestCase
  setup do
    @path = Rails.root.join("tmp/playa-seed-test-#{SecureRandom.hex(8)}.json")
    @seed = Development::PlayaSeeds.new(manifest_path: @path)
  end

  teardown do
    File.unlink(@path) if @path.exist?
    File.unlink("#{@path}.lock") if File.exist?("#{@path}.lock")
  end

  def run_on_isolated_test_database(seed = @seed)
    # Production guard stays strict; only these transactional tests bypass it.
    seed.stub(:verify_database!, true) { seed.run }
  end

  def manifest
    JSON.parse(@path.read)
  end

  test 'creates exactly 15 complete fictional adults and a private ignored credential manifest' do
    assert_no_difference ['Connection.count', 'Message.count', 'PhotoUpload.count'] do
      assert_difference ['User.count', 'Profile.count'], 15 do
        result = run_on_isolated_test_database
        assert_equal 15, result[:created_users]
        assert_equal 15, result[:created_profiles]
      end
    end
    entries = manifest.fetch('users')
    assert_equal 15, entries.size
    assert_equal 15, entries.map { |entry| entry['password'] }.uniq.size
    assert_equal Development::PlayaSeeds::COHORT, manifest['cohort']
    assert_equal 0o600, File.stat(@path).mode & 0o777
    assert system('git', 'check-ignore', '-q', '--', @path.to_s)
    users = User.where(id: entries.map { |entry| entry['user_id'] })
    profiles = Profile.where(user: users)
    assert_equal 15, Profile.complete.where(id: profiles.select(:id)).count
    assert_equal ['Playa del Carmen'], profiles.distinct.pluck(:city)
    assert_equal({ 'beginner' => 6, 'intermediate' => 6, 'advanced' => 3 }, profiles.group(:experience_level).count)
    assert profiles.all? { |profile| profile.age.between?(22, 48) && profile.dance_styles.include?('bachata') }
    assert profiles.all? { |profile| profile.primary_photo_url.start_with?('https://placehold.co/') && profile.primary_photo_upload_id.nil? }
    entries.each do |entry|
      user = User.find(entry['user_id'])
      assert user.valid_password?(entry['password'])
      assert_equal user.profile.id, entry['profile_id']
      assert_equal user.profile.display_name, entry['display_name']
    end
  end

  test 'reruns preserve IDs credentials edits relationships and unrelated accounts' do
    stranger = User.create!(email: 'unrelated@example.test', password: SecureRandom.hex(24))
    unrelated_attributes = stranger.attributes
    run_on_isolated_test_database
    before = manifest
    first, second = before['users'].first(2).map { |entry| User.find(entry['user_id']) }
    changed_password = SecureRandom.hex(24)
    first.update!(password: changed_password)
    first.profile.update!(display_name: 'Edited dancer', city: 'Edited city', bio: 'Keep this edit')
    connection = Connection.create!(requester: first, recipient: second, intro_message: 'Practice together?')
    connection.transition!(second, 'accepted')
    message = Message.create!(connection: connection, sender: first, body: 'Keep this message')
    snapshot = [first.reload.attributes, first.profile.attributes, connection.attributes, message.attributes]
    assert_no_difference ['User.count', 'Profile.count', 'Connection.count', 'Message.count'] do
      result = run_on_isolated_test_database
      assert_equal 0, result[:created_users]
      assert_equal 0, result[:created_profiles]
    end
    assert_equal before['users'].map { |entry| entry.values_at('user_id', 'profile_id', 'password') },
                 manifest['users'].map { |entry| entry.values_at('user_id', 'profile_id', 'password') }
    assert_equal snapshot, [first.reload.attributes, first.profile.reload.attributes, connection.reload.attributes, message.reload.attributes]
    assert_equal unrelated_attributes, stranger.reload.attributes
    assert first.valid_password?(changed_password)
  end

  test 'missing owned account or profile is recreated using its retained password without duplicates' do
    run_on_isolated_test_database
    before = manifest
    first, second = before['users'].first(2)
    User.find(first['user_id']).destroy!
    User.find(second['user_id']).profile.destroy!
    result = nil
    assert_difference('User.count', 1) do
      assert_difference('Profile.count', 2) { result = run_on_isolated_test_database }
    end
    assert_equal 1, result[:created_users]
    assert_equal 2, result[:created_profiles]
    assert_equal 15, User.where(email: before['users'].map { |entry| entry['email'] }).count
    assert_equal 15, Profile.where(user_id: manifest['users'].map { |entry| entry['user_id'] }).count
    assert_equal first['password'], manifest['users'][0]['password']
    assert User.find(manifest['users'][0]['user_id']).valid_password?(first['password'])
    assert_equal second['user_id'], manifest['users'][1]['user_id']
  end

  test 'missing or corrupt manifest and ambiguous email collisions do not adopt or reset accounts' do
    existing = User.create!(email: 'playa01@bailaduo.test', password: SecureRandom.hex(24))
    original = existing.attributes
    assert_no_difference ['User.count', 'Profile.count'] do
      error = assert_raises(Development::PlayaSeeds::Refused) { run_on_isolated_test_database }
      assert_match(/collision/, error.message)
    end
    assert_equal original, existing.reload.attributes
    assert_not @path.exist?
    @path.write('{corrupt')
    assert_no_difference ['User.count', 'Profile.count'] do
      assert_raises(Development::PlayaSeeds::Refused) { run_on_isolated_test_database }
    end
    assert_equal original, existing.reload.attributes
  end

  test 'mismatched manifest identity and foreign manifest are refused without writes' do
    run_on_isolated_test_database
    data = manifest
    data['users'][0]['user_created_at'] = 1.day.ago.iso8601(6)
    @path.write(JSON.generate(data))
    assert_no_difference ['User.count', 'Profile.count'] do
      assert_raises(Development::PlayaSeeds::Refused) { run_on_isolated_test_database }
    end
    data['cohort'] = 'another-cohort'
    @path.write(JSON.generate(data))
    assert_raises(Development::PlayaSeeds::Refused) { run_on_isolated_test_database }
  end

  test 'lost manifest never recreates credentials or adopts existing cohort accounts' do
    run_on_isolated_test_database
    original = User.order(:id).pluck(:id, :encrypted_password)
    @path.unlink
    assert_no_difference ['User.count', 'Profile.count'] do
      assert_raises(Development::PlayaSeeds::Refused) { run_on_isolated_test_database }
    end
    assert_equal original, User.order(:id).pluck(:id, :encrypted_password)
    assert_not @path.exist?
  end

  test 'symlink manifests and paths outside ignored tmp are refused before writes' do
    target = Rails.root.join("tmp/playa-seed-target-#{SecureRandom.hex(8)}")
    target.write('Keep this file')
    begin
      File.symlink(target, @path)
      assert_no_difference ['User.count', 'Profile.count'] do
        assert_raises(Development::PlayaSeeds::Refused) { run_on_isolated_test_database }
        outside = Development::PlayaSeeds.new(manifest_path: Rails.root.join('public/playa-test-users.json'))
        assert_raises(Development::PlayaSeeds::Refused) { run_on_isolated_test_database(outside) }
      end
      assert_equal 'Keep this file', target.read
    ensure
      @path.unlink if @path.symlink?
      target.unlink
    end
  end

  test 'manifest write failure rolls back accounts and profiles' do
    @seed.stub(:write_manifest, ->(*) { raise IOError, 'Simulated disk failure' }) do
      assert_no_difference ['User.count', 'Profile.count'] do
        assert_raises(IOError) { run_on_isolated_test_database }
      end
    end
    assert_not @path.exist?
  end

  test 'test and production environments are refused before any seed writes or file creation' do
    %w[test production].each do |environment|
      Rails.stub(:env, ActiveSupport::StringInquirer.new(environment)) do
        assert_no_difference ['User.count', 'Profile.count'] do
          assert_raises(Development::PlayaSeeds::Refused) { @seed.run }
        end
        assert_not @path.exist?
        assert_not File.exist?("#{@path}.lock")
      end
    end
  end

  def with_connection_identity(config_overrides: {}, raw_overrides: {}, actual_overrides: {})
    config = { adapter: 'postgresql', database: Development::PlayaSeeds::DATABASE, host: nil, port: 5432 }.merge(config_overrides)
    raw = Struct.new(:db, :host, :port).new(*{ db: Development::PlayaSeeds::DATABASE, host: '/tmp', port: 5432 }.merge(raw_overrides).values)
    actual = { 'database' => Development::PlayaSeeds::DATABASE, 'address' => nil, 'port' => '5432' }.merge(actual_overrides)
    connection = Object.new
    connection.define_singleton_method(:raw_connection) { raw }
    connection.define_singleton_method(:select_one) { |*| actual }
    Rails.stub(:env, ActiveSupport::StringInquirer.new('development')) do
      User.stub(:connection_db_config, Struct.new(:configuration_hash).new(config)) do
        User.stub(:connection, connection) { yield }
      end
    end
  end

  test 'guard checks configured and actual connection including environment overrides before filesystem writes' do
    [
      { config_overrides: { database: 'jabngo_development' } },
      { config_overrides: { database: 'bailaduo_api_production' } },
      { config_overrides: { host: 'example.neon.tech' } },
      { config_overrides: { host: '192.0.2.1' } },
      { config_overrides: { port: 5433 } },
      { raw_overrides: { host: 'example.neon.tech' } },
      { raw_overrides: { db: 'other_development' } },
      { raw_overrides: { port: 5433 } },
      { actual_overrides: { 'database' => 'other_development' } },
      { actual_overrides: { 'address' => '192.0.2.1' } },
      { actual_overrides: { 'port' => '5433' } }
    ].each do |identity|
      with_connection_identity(**identity) do
        assert_raises(Development::PlayaSeeds::Refused) { @seed.run }
      end
      assert_not @path.exist?
      assert_not File.exist?("#{@path}.lock")
    end
    with_connection_identity { assert_nothing_raised { @seed.verify_database! } }
  end
end
