require 'test_helper'
require_relative '../support/photo_helpers'

class CloudflareImagesTest < ActiveSupport::TestCase
  include PhotoHelpers

  setup do
    configure_photos
    user = User.create!(email: 'provider@example.test', password: SecureRandom.hex(16))
    @upload = photo_record(user)
    @client = CloudflareImages.new
    @requests = []
  end
  teardown { restore_photo_configuration }

  test 'configuration uses provider-compatible alphanumeric environment-specific variant names' do
    assert_instance_of CloudflareImages, CloudflareImages.new
    ['bailaduo-test-profile', 'bailaduoproductionprofile', 'public'].each do |variant|
      ENV['BAILADUO_CLOUDFLARE_IMAGES_VARIANT'] = variant
      assert_raises(CloudflareImages::NotConfigured) { CloudflareImages.new }
    end
  end

  def response(data, code: '200')
    klass = code == '404' ? Net::HTTPNotFound : Net::HTTPOK
    response = klass.new('1.1', code, 'test')
    chunks = data.is_a?(Array) ? data : [data]
    response.define_singleton_method(:read_body) { |&block| chunks.each(&block) }
    response
  end

  def with_responses(*responses, &block)
    transport = lambda do |request, &consumer|
      @requests << request
      consumer.call(responses.shift || raise('Unexpected provider request'))
    end
    @client.stub(:transport, transport, &block)
  end

  def details(overrides = {})
    { id: @upload.provider_image_id, uploaded: Time.current.iso8601, requireSignedURLs: false,
      variants: ["https://imagedelivery.net/testhash/#{@upload.provider_image_id}/bailaduotestprofile"] }.merge(overrides)
  end

  def json_response(result)
    response({ success: true, result: result }.to_json)
  end

  test 'direct issuance uses only the dedicated account and rejects foreign upload hosts' do
    with_responses(json_response(id: @upload.provider_image_id, uploadURL: 'https://upload.imagedelivery.net/testhash/temporary')) do
      assert @client.issue(@upload).start_with?('https://upload.imagedelivery.net/')
    end
    assert_equal '/client/v4/accounts/testaccount/images/v2/direct_upload', @requests.first.path
    assert @requests.first['Authorization'].present?
    with_responses(json_response(id: @upload.provider_image_id, uploadURL: 'https://unrelated.example.test/upload')) do
      assert_raises(CloudflareImages::Error) { @client.issue(@upload) }
    end
  end

  test 'verification checks provider draft exact ID variant and inspected original bytes' do
    with_responses(json_response(details), response("\x89PNG\r\n\x1A\n".b + 'photo')) do
      verified = @client.verify(@upload)
      assert_equal 'image/png', verified[:content_type]
      assert_equal 13, verified[:byte_size]
      assert_equal details[:variants].first, verified[:delivery_url]
    end
    assert_equal "/client/v4/accounts/testaccount/images/v1/#{@upload.provider_image_id}/blob", @requests.last.path
    with_responses(json_response(details(draft: true))) do
      assert_raises(CloudflareImages::NotReady) { @client.verify(@upload) }
    end
    [details(id: 'jabngo-asset'), details(variants: ['https://imagedelivery.net/foreign/unrelated/public']), details(uploaded: nil)].each do |result|
      with_responses(json_response(result)) { assert_raises(CloudflareImages::InvalidImage) { @client.verify(@upload) } }
    end
  end

  test 'actual oversized and unsupported content is refused regardless of client declarations' do
    with_responses(json_response(details), response(['RIFF0000WEBP', 'x' * 5_000_000])) do
      assert_raises(CloudflareImages::InvalidImage) { @client.verify(@upload) }
    end
    with_responses(json_response(details), response('<svg>unsupported</svg>')) do
      assert_raises(CloudflareImages::InvalidImage) { @client.verify(@upload) }
    end
  end

  test 'environment identity prevents any provider operation on unrelated records' do
    @upload.update!(provider_image_id: 'jabngo-asset')
    with_responses do
      assert_raises(CloudflareImages::InvalidImage) { @client.issue(@upload) }
      assert_raises(CloudflareImages::InvalidImage) { @client.verify(@upload) }
      assert_raises(CloudflareImages::InvalidImage) { @client.delete(@upload) }
    end
    assert_empty @requests
  end

  test 'provider failures are sanitized and a missing owned image deletes idempotently' do
    with_responses(response('provider secret details', code: '404')) do
      error = assert_raises(CloudflareImages::Error) { @client.verify(@upload) }
      assert_not_includes error.message, 'provider secret'
    end
    with_responses(response('', code: '404')) { assert @client.delete(@upload) }
    assert_equal 'DELETE', @requests.last.method
    with_responses(response({ success: true, result: nil }.to_json)) do
      assert_raises(CloudflareImages::Error) { @client.issue(@upload) }
    end
  end

  test 'network and protocol errors never expose raw request information' do
    [Net::ReadTimeout, Net::HTTPBadResponse].each do |error_class|
      Net::HTTP.stub(:start, ->(*) { raise error_class, 'private-request-detail' }) do
        error = assert_raises(CloudflareImages::Error) { @client.issue(@upload) }
        assert_equal 'Images provider is unavailable; please retry', error.message
      end
    end
  end
end
