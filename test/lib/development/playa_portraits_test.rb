require 'test_helper'
require_relative '../../support/photo_helpers'

class Development::PlayaPortraitsTest < ActiveSupport::TestCase
  include PhotoHelpers

  class PortraitApi
    attr_reader :issued, :uploaded
    attr_accessor :fail_completion, :before_attach

    def initialize(provider)
      @provider, @issued, @uploaded = provider, [], []
    end

    def with_session(entry)
      @user = User.find(entry.fetch('user_id'))
      yield
    end

    def json(method, path, body = nil, expected: 200)
      return { 'data' => @user.profile.reload.public_data } if method == :get && path == '/api/profile'
      if method == :post && path == '/api/photo_uploads'
        upload, url = PhotoUpload.issue_for!(@user, **body.fetch(:photo_upload), provider: @provider)
        @issued << upload.id
        return { 'data' => { 'id' => upload.id, 'upload_url' => url } }
      end
      if method == :post && path.match?(%r{\A/api/photo_uploads/\d+/complete\z})
        upload = @user.photo_uploads.find(path.split('/')[3])
        upload.verify!(provider: @provider)
        if fail_completion
          self.fail_completion = false
          raise Development::PlayaSeeds::Refused, 'Simulated interrupted confirmation'
        end
        before_attach&.call(@user.profile)
        return { 'data' => upload.owner_data }
      end
      raise "Unexpected portrait test request: #{method} #{path}"
    end

    def upload(_url, path)
      @uploaded << Digest::SHA256.file(path).hexdigest
    end
  end

  setup do
    configure_photos
    ENV['BAILADUO_MEDIA_ENVIRONMENT'] = 'development'
    ENV['BAILADUO_CLOUDFLARE_IMAGES_VARIANT'] = 'bailaduodevelopmentprofile'
    suffix = SecureRandom.hex(8)
    @credentials = Rails.root.join("tmp/playa-portrait-test-#{suffix}.json")
    @progress = Rails.root.join("tmp/playa-portrait-progress-test-#{suffix}.json")
    @seed = Development::PlayaSeeds.new(manifest_path: @credentials)
    @seed.stub(:verify_database!, true) { @seed.run }
    @original_credentials = @credentials.binread
    @provider = Provider.new
    @api = PortraitApi.new(@provider)
    @refresh = Development::PlayaPortraits.new(seed: @seed, api: @api, progress_path: @progress)
    @entries = JSON.parse(@credentials.read).fetch('users')
  end

  teardown do
    [@credentials, @progress, Pathname.new("#{@credentials}.lock"), Pathname.new("#{@progress}.lock")].each do |path|
      path.unlink if path.exist?
    end
    restore_photo_configuration
  end

  def refresh
    @seed.stub(:verify_database!, true) do
      CloudflareImages.stub(:new, @provider) { @refresh.run }
    end
  end

  test 'supplied portraits attach once with stable mapping and no account or credential changes' do
    users_before = User.order(:id).map(&:attributes)
    profiles_before = Profile.order(:id).map { |profile| profile.attributes.except('primary_photo_url', 'primary_photo_upload_id', 'updated_at') }
    assert_no_difference ['User.count', 'Profile.count', 'Connection.count', 'Message.count'] do
      assert_difference('PhotoUpload.count', 15) { assert_equal({ attached: 15, preserved: 0 }, refresh) }
    end
    assert_equal @original_credentials, @credentials.binread
    assert_equal users_before, User.order(:id).map(&:attributes)
    assert_equal profiles_before, Profile.order(:id).map { |profile| profile.attributes.except('primary_photo_url', 'primary_photo_upload_id', 'updated_at') }
    manifest = JSON.parse(Development::PlayaPortraits::ASSETS.join('manifest.json').read)
    assert_equal manifest['portraits'].map { |portrait| portrait['sha256'] }, @api.uploaded
    @entries.each do |entry|
      profile = Profile.find(entry.fetch('profile_id'))
      assert_equal entry['user_id'], profile.primary_photo_upload.user_id
      assert_equal 'attached', profile.primary_photo_upload.status
      assert_equal profile.primary_photo_upload.delivery_url, profile.primary_photo_url
    end
    mapping = Profile.order(:id).pluck(:id, :primary_photo_upload_id, :primary_photo_url)
    assert_no_difference('PhotoUpload.count') { assert_equal({ attached: 0, preserved: 15 }, refresh) }
    assert_equal mapping, Profile.order(:id).pluck(:id, :primary_photo_upload_id, :primary_photo_url)
    assert_equal 15, @api.issued.size
    assert_equal 0o600, @progress.stat.mode & 0o777
  end

  test 'manual replacements and wrong numbered references are preserved without upload' do
    first = Profile.find(@entries[0]['profile_id'])
    first.update!(primary_photo_url: 'https://images.example.test/manually-selected.jpg', bio: 'Keep my edits')
    second = Profile.find(@entries[1]['profile_id'])
    second.update!(primary_photo_url: first.primary_photo_url)
    before = [first.reload.attributes, second.reload.attributes]
    assert_equal({ attached: 13, preserved: 2 }, refresh)
    assert_equal before, [first.reload.attributes, second.reload.attributes]
    assert_equal 13, @api.uploaded.size
    assert_equal @original_credentials, @credentials.binread
  end

  test 'a manual photo selected during upload wins the locked attachment recheck' do
    @api.before_attach = ->(profile) { profile.update!(primary_photo_url: 'https://images.example.test/concurrent-manual.jpg') }
    assert_equal({ attached: 0, preserved: 15 }, refresh)
    assert Profile.all.all? { |profile| profile.primary_photo_upload_id.nil? && profile.primary_photo_url.end_with?('/concurrent-manual.jpg') }
    assert_no_difference('PhotoUpload.count') { refresh }
  end

  test 'interrupted confirmation resumes the saved owned upload without uploading it twice' do
    @api.fail_completion = true
    assert_raises(Development::PlayaSeeds::Refused) { refresh }
    assert_equal 1, @api.issued.size
    assert_equal 1, @api.uploaded.size
    assert_equal({ attached: 15, preserved: 0 }, refresh)
    assert_equal 15, @api.issued.size
    assert_equal 15, @api.uploaded.size
  end

  test 'nondevelopment media and foreign progress identity are refused before issuing uploads' do
    @provider.stub(:environment, 'production') do
      assert_raises(Development::PlayaSeeds::Refused) { refresh }
    end
    @progress.write(JSON.generate(cohort: 'foreign', database: Development::PlayaSeeds::DATABASE, uploads: {}))
    assert_raises(Development::PlayaSeeds::Refused) { refresh }
    assert_empty @api.issued
  end

  test 'real environment guard refuses portrait refresh on the isolated test database' do
    guarded = Development::PlayaPortraits.new(api: @api, progress_path: @progress)
    assert_raises(Development::PlayaSeeds::Refused) { guarded.run }
    assert_empty @api.issued
  end
end
