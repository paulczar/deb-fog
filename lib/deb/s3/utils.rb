require "base64"
require "digest/md5"
require "erb"
require "tmpdir"

module Deb::S3::Utils
  module_function
  def s3; @s3 end
  def s3= v; @s3 = v end
  def bucket; @bucket end
  def bucket= v; @bucket = v end
  def is_public; @is_public end
  def is_public= v; @is_public = v end
  def signing_key; @signing_key end
  def signing_key= v; @signing_key = v end
  def gpg_options; @gpg_options end
  def gpg_options= v; @gpg_options = v end
  def prefix; @prefix end
  def prefix= v; @prefix = v end

  class SafeSystemError < RuntimeError; end

  def safesystem(*args)
    success = system(*args)
    if !success
      raise SafeSystemError, "'system(#{args.inspect})' failed with error code: #{$?.exitstatus}"
    end
    return success
  end

  def debianize_op(op)
    # Operators in debian packaging are <<, <=, =, >= and >>
    # So any operator like < or > must be replaced
    {:< => "<<", :> => ">>"}[op.to_sym] or op
  end

  def template(path)
    template_file = File.join(File.dirname(__FILE__), "templates", path)
    template_code = File.read(template_file)
    ERB.new(template_code, nil, "-")
  end

  def s3_path(path)
    File.join(*[Deb::S3::Utils.prefix, path].compact)
  end

  # from fog, Fog::AWS.escape
  def s3_escape(string)
    string.gsub(/([^a-zA-Z0-9_.\-~]+)/) {
      "%" + $1.unpack("H2" * $1.bytesize).join("%").upcase
    }
  end

  def s3_exists?(path)
    return true if Deb::S3::Utils.bucket.files.head(File.basename(path))
    return false
  end

  def s3_read(path)
    #puts "blerg: #{Deb::S3::Utils.bucket.files}"
    return nil unless s3_exists?(path)
    Deb::S3::Utils.bucket.files[s3_path(path)].read
  end

  def s3_store(path, filename=nil, content_type='application/octet-stream; charset=binary')
    filename = File.basename(path) unless filename
    obj = Deb::S3::Utils.bucket.files.head(filename)
    # check if the object already exists
    unless obj.nil?
      file_md5 = Digest::MD5.file(path)
      return if file_md5.to_s == obj.etag.gsub('"', '')
    end

    # upload the file
    file = Deb::S3::Utils.bucket.files.create(
      :key    => s3_path(filename),
      :body   => File.open(path),
      :public => Deb::S3::Utils.is_public,
      :content_type => content_type
    )
    # obj.write(Pathname.new(path), :acl => Deb::S3::Utils.access_policy, :content_type => content_type)
  end

  def s3_remove(path)
    Deb::S3::Utils.bucket.files[s3_path(path)].destroy if s3_exists?(path)
  end
end
