require 'fileutils'
require 'rack/lint'
require 'rack/sendfile'
require 'rack/mock'
require 'tmpdir'

describe Rack::File do
  should "respond to #to_path" do
    Rack::File.new(Dir.pwd).should.respond_to :to_path
  end
end

describe Rack::Sendfile do
  def sendfile_body
    FileUtils.touch File.join(Dir.tmpdir,  "rack_sendfile")
    res = ['Hello World']
    def res.to_path ; File.join(Dir.tmpdir,  "rack_sendfile") ; end
    res
  end

  def simple_app(body=sendfile_body)
    lambda { |env| [200, {'Content-Type' => 'text/plain'}, body] }
  end

  def sendfile_app(body, mappings = [], variation = nil)
    Rack::Lint.new Rack::Sendfile.new(simple_app(body), variation, mappings)
  end

  def request(headers = {}, body = sendfile_body, mappings = [], variation = nil)
    yield Rack::MockRequest.new(sendfile_app(body, mappings, variation)).get('/', headers)
  end

  def open_file(path)
    Class.new(File) do
      unless method_defined?(:to_path)
        alias :to_path :path
      end
    end.open(path, 'wb+')
  end

  it "does nothing when no X-Sendfile-Type header present" do
    request do |response|
      response.should.be.ok
      response.body.should.equal 'Hello World'
      response.headers.should.not.include 'X-Sendfile'
    end
  end

  it "sets X-Sendfile response header and discards body" do
    request 'HTTP_X_SENDFILE_TYPE' => 'X-Sendfile' do |response|
      response.should.be.ok
      response.body.should.be.empty
      response.headers['Content-Length'].should.equal '0'
      response.headers['X-Sendfile'].should.equal File.join(Dir.tmpdir,  "rack_sendfile")
    end
  end

  it "sets X-Lighttpd-Send-File response header and discards body" do
    request 'HTTP_X_SENDFILE_TYPE' => 'X-Lighttpd-Send-File' do |response|
      response.should.be.ok
      response.body.should.be.empty
      response.headers['Content-Length'].should.equal '0'
      response.headers['X-Lighttpd-Send-File'].should.equal File.join(Dir.tmpdir,  "rack_sendfile")
    end
  end

  it "does not sets X-Accel-Redirect response header when it is set via X-Sendfile-Type" do
    headers = {
      'HTTP_X_SENDFILE_TYPE' => 'X-Accel-Redirect',
      'HTTP_X_ACCEL_MAPPING' => "#{Dir.tmpdir}/=/foo/bar/"
    }
    request headers do |response|
      response.should.be.ok
      response.body.should.equal 'Hello World'
      response.headers.should.not.include 'X-Accel-Redirect'
    end
  end

  it "sets X-Accel-Redirect response header and discards body when set explicitly" do
    headers = {
      'HTTP_X_ACCEL_MAPPING' => "#{Dir.tmpdir}/=/foo/bar/"
    }
    request(headers, sendfile_body, [], 'X-Accel-Redirect') do |response|
      response.should.be.ok
      response.body.should.be.empty
      response.headers['Content-Length'].should.equal '0'
      response.headers['X-Accel-Redirect'].should.equal '/foo/bar/rack_sendfile'
    end
  end

  it 'writes to rack.error when no X-Accel-Mapping is specified' do
    request({}, sendfile_body, [], 'X-Accel-Redirect') do |response|
      response.should.be.ok
      response.body.should.equal 'Hello World'
      response.headers.should.not.include 'X-Accel-Redirect'
      response.errors.should.include 'X-Accel-Mapping'
    end
  end

  it 'does nothing when body does not respond to #to_path' do
    request({'HTTP_X_SENDFILE_TYPE' => 'X-Sendfile'}, ['Not a file...']) do |response|
      response.body.should.equal 'Not a file...'
      response.headers.should.not.include 'X-Sendfile'
    end
  end

  it "sets X-Accel-Redirect response header and discards body when initialized with multiple mappings" do
    begin
      dir1 = Dir.mktmpdir
      dir2 = Dir.mktmpdir

      first_body = open_file(File.join(dir1, 'rack_sendfile'))
      first_body.puts 'hello world'

      second_body = open_file(File.join(dir2, 'rack_sendfile'))
      second_body.puts 'goodbye world'

      mappings = [
        ["#{dir1}/", '/foo/bar/'],
        ["#{dir2}/", '/wibble/']
      ]

      request({}, first_body, mappings, 'X-Accel-Redirect') do |response|
        response.should.be.ok
        response.body.should.be.empty
        response.headers['Content-Length'].should.equal '0'
        response.headers['X-Accel-Redirect'].should.equal '/foo/bar/rack_sendfile'
      end

      request({}, second_body, mappings, 'X-Accel-Redirect') do |response|
        response.should.be.ok
        response.body.should.be.empty
        response.headers['Content-Length'].should.equal '0'
        response.headers['X-Accel-Redirect'].should.equal '/wibble/rack_sendfile'
      end
    ensure
      FileUtils.remove_entry_secure dir1
      FileUtils.remove_entry_secure dir2
    end
  end

  it "ignores HTTP_X_ACCEL_MAPPING when application-level mappings are configured" do
    # When app provides mappings, header should be ignored for security
    begin
      dir = Dir.mktmpdir
      body = open_file(File.join(dir, 'rack_sendfile'))
      body.puts 'test'

      app_mappings = [["#{dir}/", '/app/mapping/']]
      app = Rack::Lint.new Rack::Sendfile.new(simple_app(body), "X-Accel-Redirect", app_mappings)

      headers = {
        'HTTP_X_ACCEL_MAPPING' => "#{dir}/=/attacker/path/"
      }

      response = Rack::MockRequest.new(app).get('/', headers)
      response.should.be.ok
      response.body.should.be.empty
      response.headers['x-accel-redirect'].should.equal '/app/mapping/rack_sendfile'
      response.headers['x-accel-redirect'].should.not.equal '/attacker/path/rack_sendfile'
    ensure
      FileUtils.remove_entry_secure dir
    end
  end

  it "allows HTTP_X_ACCEL_MAPPING only when x-accel-redirect explicitly enabled with no app mappings" do
    # This is the safe use case: explicit config + no app mappings = allow header
    begin
      dir = Dir.mktmpdir
      body = open_file(File.join(dir, 'rack_sendfile'))
      body.puts 'test'

      app = Rack::Lint.new Rack::Sendfile.new(simple_app(body), "X-Accel-Redirect", [])

      headers = {
        'HTTP_X_ACCEL_MAPPING' => "#{dir}/=/safe/nginx/mapping/"
      }

      response = Rack::MockRequest.new(app).get('/', headers)
      response.should.be.ok
      response.body.should.be.empty
      response.headers['x-accel-redirect'].should.equal '/safe/nginx/mapping/rack_sendfile'
    ensure
      FileUtils.remove_entry_secure dir
    end
  end
end
