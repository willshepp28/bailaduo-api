require 'test_helper'
require_relative '../support/photo_helpers'
require 'timeout'

class PhotoIssuanceConcurrencyTest < ActiveSupport::TestCase
  include PhotoHelpers
  self.use_transactional_tests = false

  test 'concurrent issuance cannot exceed active upload slots' do
    configure_photos
    user = User.create!(email: "#{SecureRandom.hex(12)}@example.test", password: SecureRandom.hex(16))
    2.times { photo_record(user) }
    ready = Queue.new
    release = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          viewer = User.find(user.id)
          provider = Provider.new
          ready << true
          release.pop
          begin
            PhotoUpload.issue_for!(viewer, content_type: 'image/png', byte_size: 128, provider: provider)
            :issued
          rescue PhotoUpload::QuotaExceeded
            :limited
          end
        end
      end
    end
    Timeout.timeout(10) { 2.times { ready.pop } }
    2.times { release << true }
    assert_equal [:issued, :limited], Timeout.timeout(15) { threads.map(&:value) }.sort
    assert_equal 3, PhotoUpload.where(user: user).count
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
    threads&.each(&:join)
    PhotoUpload.where(user: user).delete_all if user
    user&.destroy!
    restore_photo_configuration
  end
end
