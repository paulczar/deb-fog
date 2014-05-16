require "fog"
require "thor"

# Hack: aws requires this!
require "json"

require "deb/fog"
require "deb/fog/utils"
require "deb/fog/manifest"
require "deb/fog/package"
require "deb/fog/release"

class Deb::Fog::CLI < Thor
  class_option :bucket,
  :type     => :string,
  :aliases  => "-b",
  :desc     => "The name of the Fog bucket to upload to."

  class_option :localroot,
  :type     => :string,
  :desc     => "The root direcotry of local storage."

  class_option :prefix,
  :type     => :string,
  :desc     => "The path prefix to use when storing on Fog."

  class_option :codename,
  :default  => "stable",
  :type     => :string,
  :aliases  => "-c",
  :desc     => "The codename of the APT repository."

  class_option :component,
  :default  => "main",
  :type     => :string,
  :aliases  => "-m",
  :desc     => "The component of the APT repository."

  class_option :section,
  :type     => :string,
  :aliases  => "-s",
  :hide     => true

  class_option :provider,
  :type     => :string,
  :desc     => "The Cloud Provider to use: AWS|Google|Rackspace"

  class_option :access_key_id,
  :type     => :string,
  :desc     => "The access key for connecting to Fog."

  class_option :secret_access_key,
  :type     => :string,
  :desc     => "The secret key for connecting to Fog."

  class_option :endpoint,
  :type     => :string,
  :desc     => "The region endpoint for connecting to Fog.",
  :default  => "fog.amazonaws.com"

  class_option :visibility,
  :default  => "public",
  :type     => :string,
  :aliases  => "-v",
  :desc     => "The access policy for the uploaded files. " +
    "Can be public, private, or authenticated."

  class_option :sign,
  :type     => :string,
  :desc     => "Sign the Release file when uploading a package," +
    "or when verifying it after removing a package." +
    "Use --sign with your key ID to use a specific key."

  class_option :gpg_options,
  :default => "",
  :type    => :string,
  :desc    => "Additional command line options to pass to GPG when signing"

  desc "upload FILES",
  "Uploads the given files to a Fog bucket as an APT repository."

  option :arch,
  :type     => :string,
  :aliases  => "-a",
  :desc     => "The architecture of the package in the APT repository."

  option :preserve_versions,
  :default  => false,
  :type     => :boolean,
  :aliases  => "-p",
  :desc     => "Whether to preserve other versions of a package " +
    "in the repository when uploading one."

  def upload(*files)
    log(options)
    component = options[:component]
    if options[:section]
      component = options[:section]
      warn("===> WARNING: The --section/-s argument is deprecated, please use --component/-m.")
    end

    if files.nil? || files.empty?
      error("You must specify at least one file to upload")
    end

    # make sure all the files exists
    if missing_file = files.detect { |f| !File.exists?(f) }
      error("File '#{missing_file}' doesn't exist")
    end

    # configure AWS::Fog
    configure_fog_client

    # retrieve the existing manifests
    log("Retrieving existing manifests")
    release  = Deb::Fog::Release.retrieve(options[:codename])
    manifests = {}

    # examine all the files
    files.collect { |f| Dir.glob(f) }.flatten.each do |file|
      log("Examining package file #{File.basename(file)}")
      pkg = Deb::Fog::Package.parse_file(file)

      # copy over some options if they weren't given
      arch = options[:arch] || pkg.architecture

      # validate we have them
      error("No architcture given and unable to determine one for #{file}. " +
            "Please specify one with --arch [i386,amd64].") unless arch

      # retrieve the manifest for the arch if we don't have it already
      manifests[arch] ||= Deb::Fog::Manifest.retrieve(options[:codename], component, arch)

      # add in the package
      manifests[arch].add(pkg, options[:preserve_versions])
    end

    # upload the manifest
    log("Uploading packages and new manifests to Fog")
    manifests.each_value do |manifest|
      manifest.write_to_fog { |f| sublog("Transferring #{f}") }
      release.update_manifest(manifest)
    end
    release.write_to_fog { |f| sublog("Transferring #{f}") }

    log("Update complete.")
  end

  desc "delete PACKAGE",
    "Remove the package named PACKAGE. If --versions is not specified, delete" +
    "all versions of PACKAGE. Otherwise, only the specified versions will be " +
    "deleted."

  option :arch,
    :type     => :string,
    :aliases  => "-a",
    :desc     => "The architecture of the package in the APT repository."

  option :versions,
    :default  => nil,
    :type     => :array,
    :desc     => "The space-delimited versions of PACKAGE to delete. If not" +
    "specified, ALL VERSIONS will be deleted. Fair warning." +
    "E.g. --versions \"0.1 0.2 0.3\""

  def delete(package)
    component = options[:component]
    if options[:section]
      component = options[:section]
      warn("===> WARNING: The --section/-s argument is deprecated, please use --component/-m.")
    end

    if package.nil?
      error("You must specify a package name.")
    end

    versions = options[:versions]
    if versions.nil?
      warn("===> WARNING: Deleting all versions of #{package}")
    else
      log("Versions to delete: #{versions.join(', ')}")
    end

    arch = options[:arch]
    if arch.nil?
      error("You must specify the architecture of the package to remove.")
    end

    configure_fog_client

    # retrieve the existing manifests
    log("Retrieving existing manifests")
    release  = Deb::Fog::Release.retrieve(options[:codename])
    manifest = Deb::Fog::Manifest.retrieve(options[:codename], component, options[:arch])

    deleted = manifest.delete_package(package, versions)
    if deleted.length == 0
        if versions.nil?
            error("No packages were deleted. #{package} not found.")
        else
            error("No packages were deleted. #{package} versions #{versions.join(', ')} could not be found.")
        end
    else
        deleted.each { |p|
            sublog("Deleting #{p.name} version #{p.version}")
        }
    end

    log("Uploading new manifests to Fog")
    manifest.write_to_fog {|f| sublog("Transferring #{f}") }
    release.update_manifest(manifest)
    release.write_to_fog {|f| sublog("Transferring #{f}") }

    log("Update complete.")
  end


  desc "verify", "Verifies that the files in the package manifests exist"

  option :fix_manifests,
  :default  => false,
  :type     => :boolean,
  :aliases  => "-f",
  :desc     => "Whether to fix problems in manifests when verifying."

  def verify
    component = options[:component]
    if options[:section]
      component = options[:section]
      warn("===> WARNING: The --section/-s argument is deprecated, please use --component/-m.")
    end

    configure_fog_client

    log("Retrieving existing manifests")
    release = Deb::Fog::Release.retrieve(options[:codename])

    %w[amd64 armel i386 all].each do |arch|
      log("Checking for missing packages in: #{options[:codename]}/#{options[:component]} #{arch}")
      manifest = Deb::Fog::Manifest.retrieve(options[:codename], component, arch)
      missing_packages = []

      manifest.packages.each do |p|
        unless Deb::Fog::Utils.fog_exists? p.url_filename_encoded
          sublog("The following packages are missing:\n\n") if missing_packages.empty?
          puts(p.generate)
          puts("")

          missing_packages << p
        end
      end

      if options[:fix_manifests] && !missing_packages.empty?
        log("Removing #{missing_packages.length} package(s) from the manifest...")
        missing_packages.each { |p| manifest.packages.delete(p) }
        manifest.write_to_fog { |f| sublog("Transferring #{f}") }
        release.update_manifest(manifest)
        release.write_to_fog { |f| sublog("Transferring #{f}") }

        log("Update complete.")
      end
    end
  end

  private

  def log(message)
    puts ">> #{message}"
  end

  def sublog(message)
    puts "   -- #{message}"
  end

  def error(message)
    puts "!! #{message}"
    exit 1
  end

  def configure_fog_client
    error("No value provided for required options '--bucket'") unless options[:bucket]
    credentials = {:provider => options[:provider]}
    case credentials[:provider]
    when 'AWS'
      credentials[:aws_access_key_id] = options[:access_key_id]     if options[:access_key_id]
      credentials[:aws_secret_access_key]  = options[:secret_access_key] if options[:secret_access_key]
    when 'Rackspace'
      credentials[:rackspace_username] = options[:access_key_id]     if options[:access_key_id]
      credentials[:rackspace_api_key]  = options[:secret_access_key] if options[:secret_access_key]
    when 'local'
        error("No value provided for required options '--localroot'") unless options[:localroot]
    else
      error("Invalid provider.  Can be AWS, Rackspace or local")
    end
    
    if options[:provider] == "local" then
      credentials[:provider] = 'local'
      credentials[:local_root] = options[:localroot]
      Deb::Fog::Utils.local = true
    end

    Deb::Fog::Utils.fog         = Fog::Storage.new(credentials)
    Deb::Fog::Utils.bucket      = Deb::Fog::Utils.fog.directories.new :key => options[:bucket]
    Deb::Fog::Utils.bucket.reload
    Deb::Fog::Utils.signing_key = options[:sign]
    Deb::Fog::Utils.gpg_options = options[:gpg_options]
    Deb::Fog::Utils.prefix      = options[:prefix]

    # make sure we have a valid visibility setting
    Deb::Fog::Utils.is_public =
      case options[:visibility]
      when "public"
        true
      when "private"
        false
      else
        error("Invalid visibility setting given. Can be public or private")
      end
  end
end
