require 'webrick'

# Path to serve from (two directories down)
root = File.expand_path('public', __dir__)

unless Dir.exist?(root)
  puts "⚠️ Directory not found: #{root}"
  exit(1)
end

ALLOWED_ORIGINS = [
  'http://localhost:3000',
  'https://system.maraoke.com'
]

server = WEBrick::HTTPServer.new(
  Port: 8001,
  BindAddress: '0.0.0.0',
  DocumentRoot: root
)

server.mount_proc '/' do |req, res|
  origin = req['Origin']

  # Only allow requests from allowed origins
  if ALLOWED_ORIGINS.include?(origin)
    res['Access-Control-Allow-Origin'] = origin
    res['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS'
    res['Access-Control-Allow-Headers'] = 'Content-Type'
  end

  if req.request_method == 'OPTIONS'
    # Preflight request
    res.status = 200
    res.body = ''
  else
    path = File.join(root, req.path)
    if File.file?(path)
      res.body = File.read(path)
      res.content_type = WEBrick::HTTPUtils.mime_type(path, WEBrick::HTTPUtils::DefaultMimeTypes)
    else
      res.status = 404
      res.body = 'Not Found'
    end
  end
end

trap('INT') { server.shutdown }

puts "✅ Serving files from #{root} with CORS restricted to #{ALLOWED_ORIGINS.join(', ')}"
puts "🌐 Open http://localhost:8001 in your browser"
server.start