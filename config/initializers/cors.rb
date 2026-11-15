# Comma-separated exact frontend origins; no wildcards.
origins = ENV.fetch('FRONTEND_ORIGINS', Rails.env.development? ? 'http://localhost:5173,http://localhost:3000' : '')
             .split(',').map(&:strip).reject(&:empty?)
origins.each do |origin|
  uri = URI.parse(origin)
  unless %w[http https].include?(uri.scheme) && uri.host.present? && !origin.include?('*') &&
         uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? && uri.path.empty?
    raise ArgumentError, 'FRONTEND_ORIGINS must contain exact HTTP(S) origins without paths or wildcards'
  end
end

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins(*origins)
    resource '/api/*', headers: :any,
             expose: %w[access-token token-type client expiry uid],
             methods: %i[get post patch delete options head]
  end
end
