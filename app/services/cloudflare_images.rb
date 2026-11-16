require 'net/http'
require 'json'

# The only provider boundary. Never list account assets or accept a client image ID.
class CloudflareImages
  class Error < StandardError; end
  class NotConfigured < Error; end
  class NotReady < Error; end
  class InvalidImage < Error; end

  MAX_BYTES = 5_000_000
  CONTENT_TYPES = %w[image/jpeg image/png image/webp].freeze

  def self.environment
    ENV.fetch('BAILADUO_MEDIA_ENVIRONMENT', Rails.env)
  end

  attr_reader :account_id, :environment

  def initialize
    @account_id = required('BAILADUO_CLOUDFLARE_ACCOUNT_ID')
    @token = required('BAILADUO_CLOUDFLARE_IMAGES_TOKEN')
    @delivery_hash = required('BAILADUO_CLOUDFLARE_IMAGES_HASH')
    @environment = self.class.environment
    @variant = required('BAILADUO_CLOUDFLARE_IMAGES_VARIANT')
    unless @account_id.match?(/\A[a-zA-Z0-9]+\z/) && @delivery_hash.match?(/\A[a-zA-Z0-9_-]+\z/) &&
           @environment.match?(/\A[a-z0-9-]+\z/) && @variant.match?(/\Abailaduo-#{Regexp.escape(@environment)}-[a-z0-9-]+\z/)
      raise NotConfigured, 'BailaDuo Images configuration is invalid'
    end
  end

  def assert_owned!(upload)
    expected = /\Abailaduo-#{Regexp.escape(environment)}-[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/
    unless upload.persisted? && upload.app == 'bailaduo' && upload.environment == environment &&
           upload.provider_account_id == account_id && upload.provider_image_id.match?(expected)
      raise InvalidImage, 'Photo does not belong to this BailaDuo environment'
    end
  end

  def issue(upload)
    assert_owned!(upload)
    result = request_json(Net::HTTP::Post, '/images/v2/direct_upload', {
      id: upload.provider_image_id, expiry: upload.expires_at.iso8601, requireSignedURLs: 'false',
      metadata: { app: 'bailaduo', environment: environment, upload_id: upload.id.to_s }.to_json
    })
    url = URI.parse(result.fetch('uploadURL'))
    unless result['id'] == upload.provider_image_id && url.is_a?(URI::HTTPS) &&
           url.host == 'upload.imagedelivery.net' && url.userinfo.nil?
      raise Error, 'Images provider returned an invalid upload authorization'
    end
    url.to_s
  rescue KeyError, URI::InvalidURIError
    raise Error, 'Images provider returned an invalid upload authorization'
  end

  def verify(upload)
    assert_owned!(upload)
    result = request_json(Net::HTTP::Get, image_path(upload))
    raise NotReady, 'Photo upload is not complete yet' if result['draft'] == true
    expected_url = "https://imagedelivery.net/#{@delivery_hash}/#{upload.provider_image_id}/#{@variant}"
    unless result['id'] == upload.provider_image_id && result['uploaded'].present? &&
           result['requireSignedURLs'] == false && Array(result['variants']).include?(expected_url)
      raise InvalidImage, 'Images provider could not verify this photo and delivery variant'
    end
    info = original_info(upload)
    info.merge(delivery_url: expected_url)
  end

  def delete(upload)
    assert_owned!(upload)
    request_json(Net::HTTP::Delete, image_path(upload), nil, allow_missing: true)
    true
  end

  private

  def required(name)
    ENV[name].presence || raise(NotConfigured, 'BailaDuo Images is not configured')
  end

  def image_path(upload)
    "/images/v1/#{upload.provider_image_id}"
  end

  def request_json(method, path, form = nil, allow_missing: false)
    request = method.new("/client/v4/accounts/#{account_id}#{path}")
    request['Authorization'] = "Bearer #{@token}"
    request.set_form(form.transform_keys(&:to_s).to_a, 'multipart/form-data') if form
    body = nil
    transport(request) do |response|
      return {} if allow_missing && response.code.to_i == 404
      raise Error, 'Images provider request failed; please retry' unless response.is_a?(Net::HTTPSuccess)
      raw = +''
      response.read_body do |chunk|
        raw << chunk
        raise Error, 'Images provider response is invalid' if raw.bytesize > 65_536
      end
      body = JSON.parse(raw)
    end
    raise Error, 'Images provider request failed; please retry' unless body.is_a?(Hash) && body['success'] == true
    result = body.fetch('result')
    raise Error, 'Images provider response is invalid' unless result.is_a?(Hash)
    result
  rescue JSON::ParserError, KeyError
    raise Error, 'Images provider response is invalid'
  end

  # Read the original only from the authenticated provider endpoint, in memory,
  # with a hard cap. Client MIME/size declarations are never proof of validity.
  def original_info(upload)
    request = Net::HTTP::Get.new("/client/v4/accounts/#{account_id}#{image_path(upload)}/blob")
    request['Authorization'] = "Bearer #{@token}"
    size = 0
    signature = +''.b
    transport(request) do |response|
      raise Error, 'Images provider could not inspect the photo' unless response.is_a?(Net::HTTPSuccess)
      response.read_body do |chunk|
        size += chunk.bytesize
        raise InvalidImage, 'Photo must be at most 5 MB' if size > MAX_BYTES
        signature << chunk.byteslice(0, [16 - signature.bytesize, 0].max) if signature.bytesize < 16
      end
    end
    type = if signature.start_with?("\xFF\xD8\xFF".b)
             'image/jpeg'
           elsif signature.start_with?("\x89PNG\r\n\x1A\n".b)
             'image/png'
           elsif signature.start_with?('RIFF') && signature.byteslice(8, 4) == 'WEBP'
             'image/webp'
           end
    raise InvalidImage, 'Photo must be JPEG, PNG, or WebP' unless type && size.positive?
    { content_type: type, byte_size: size }
  end

  def transport(request, &block)
    Net::HTTP.start('api.cloudflare.com', 443, use_ssl: true, open_timeout: 5, read_timeout: 15, write_timeout: 15) do |http|
      http.request(request, &block)
    end
  rescue Timeout::Error, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, Net::ProtocolError
    # Never return provider response bodies, signed upload URLs or request headers.
    raise Error, 'Images provider is unavailable; please retry'
  end
end
