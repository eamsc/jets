require "fileutils"
require "open-uri"
require "colorize"
require "socket"
require "net/http"
require "action_view"

# Some important folders to help understand how jets builds a project:
#
# /tmp/jets: build root where different jets projects get built.
# /tmp/jets/project: each jets project gets built in a different subdirectory.
#
# The rest of the folders are subfolders under /tmp/jets/project.
#
class Jets::Builders
  class CodeBuilder
    include Jets::AwsServices
    include Util
    extend Memoist

    attr_reader :full_project_path
    def initialize
      # Expanding to the full path and capture now.
      # Dir.chdir gets called later and we'll lose this info.
      @full_project_path = File.expand_path(Jets.root) + "/"
      @version_purger = Purger.new
    end

    def build
      check_ruby_version
      @version_purger.purge
      cache_check_message

      clean_start
      compile_assets # easier to do before we copy the project because node and yarn has been likely setup in the that dir
      compile_rails_assets
      copy_project
      Dir.chdir(full(tmp_code)) do
        # These commands run from project root
        code_setup
        package_ruby
        code_finish
      end
    end

    # Resolves the chicken-and-egg problem with md5 checksums. The handlers need
    # to reference files with the md5 checksum.  The files are the:
    #
    #   jets/code/rack-checksum.zip
    #   jets/code/bundled-checksum.zip
    #
    # We compute the checksums before we generate the node shim handlers.
    def calculate_md5s
      Md5.compute! # populates Md5.checksums hash
    end

    def generate_node_shims
      headline "Generating shims in the handlers folder."
      # Crucial that the Dir.pwd is in the tmp_code because for
      # Jets::Builders::app_files because Jets.boot set ups
      # autoload_paths and this is how project classes are loaded.
      Jets::Builders::HandlerGenerator.build!
    end

    def create_zip_files
      folders = Md5.stage_folders
      # Md5.stage_folders ["stage/bundled", "stage/code"]
      folders.each do |folder|
        zip = Md5Zip.new(folder)
        if exist_on_s3?(zip.md5_name)
          puts "Already exists: s3://#{s3_bucket}/jets/code/#{zip.md5_name}"
        else
          zip = Md5Zip.new(folder)
          zip.create
        end
      end
    end

    def exist_on_s3?(filename)
      s3_key = "jets/code/#{filename}"
      begin
        s3.head_object(bucket: s3_bucket, key: s3_key)
        true
      rescue Aws::S3::Errors::NotFound
        false
      end
    end

    def stage_area
      "#{Jets.build_root}/stage"
    end

    def code_setup
      reconfigure_development_webpacker
    end

    def code_finish
      # Reconfigure code
      store_s3_base_url
      disable_webpacker_middleware
      copy_internal_jets_code

      # Code prep and zipping
      build_lambda_layer
      check_code_size!
      calculate_md5s # must be called before generate_node_shims and create_zip_files
      generate_node_shims
      create_zip_files
    end

    def build_lambda_layer
      return if Jets.poly_only?
      lambda_layer = LambdaLayer.new
      lambda_layer.build
    end

    def check_code_size!
      CodeSize.check!
    end

    # We copy the files into the project because we cannot require simple functions
    # directly since they are wrapped by an anonymous class.
    # TODO: Do this with the other files we required the same way.
    def copy_internal_jets_code
      files = []
      files.each do |relative_path|
        src = File.expand_path("../internal/#{relative_path}", File.dirname(__FILE__))
        dest = "#{full(tmp_code)}/#{relative_path}"
        FileUtils.mkdir_p(File.dirname(dest))
        FileUtils.cp(src, dest)
      end
    end

    # Thanks https://stackoverflow.com/questions/9354595/recursively-getting-the-size-of-a-directory
    # Seems to overestimate a little bit but close enough.
    def dir_size(folder)
      Dir.glob(File.join(folder, '**', '*'))
        .select { |f| File.file?(f) }
        .map{ |f| File.size(f) }
        .inject(:+)
    end

    # Store s3 base url is needed for asset serving from s3 later. Need to package this
    # as part of the code so we have a reference to it.
    # At this point the minimal stack exists, so we can grab it with the AWS API.
    # We do not want to grab this as part of the live request because it is slow.
    def store_s3_base_url
      write_s3_base_url("config/s3_base_url.txt")
      write_s3_base_url("rack/config/s3_base_url.txt") if Jets.rack?
    end

    def write_s3_base_url(relative_path)
      full_path = "#{full(tmp_code)}/#{relative_path}"
      FileUtils.mkdir_p(File.dirname(full_path))
      IO.write(full_path, s3_base_url)
    end

    def s3_base_url
      # Allow user to set assets.base_url
      #
      #   Jets.application.configure do
      #     config.assets.base_url = "https://cloudfront.com/my/base/path"
      #   end
      #
      return Jets.config.assets.base_url if Jets.config.assets.base_url

      region = Jets.aws.region

      asset_base_url = "https://s3-#{region}.amazonaws.com"
      "#{asset_base_url}/#{s3_bucket}/jets" # s3_base_url
    end

    def s3_bucket
      Jets.aws.s3_bucket
    end

    def disable_webpacker_middleware
      full_path = "#{full(tmp_code)}/config/disable-webpacker-middleware.txt"
      FileUtils.mkdir_p(File.dirname(full_path))
      FileUtils.touch(full_path)
    end

    # This happens in the current app directory not the tmp code for simplicity.
    # This is because the node and yarn has likely been set up correctly there.
    def compile_assets
      if ENV['JETS_SKIP_ASSETS']
        puts "Skip compiling assets".colorize(:yellow) # useful for debugging
        return
      end

      headline "Compling assets in current project directory"
      # Thanks: https://stackoverflow.com/questions/4195735/get-list-of-gems-being-used-by-a-bundler-project
      webpacker_loaded = Gem.loaded_specs.keys.include?("webpacker")
      return unless webpacker_loaded

      sh("yarn install")
      webpack_command = File.exist?("#{Jets.root}bin/webpack") ?
          "bin/webpack" :
          `which webpack`.strip
      sh("JETS_ENV=#{Jets.env} #{webpack_command}")
    end

    # This happens in the current app directory not the tmp code for simplicity
    # This is because the node likely been set up correctly there.
    def compile_rails_assets
      return unless rails?

      if ENV['JETS_SKIP_ASSETS']
        puts "Skip compiling rack assets".colorize(:yellow) # useful for debugging
        return
      end

      return unless Jets.rack?

      Bundler.with_clean_env do
        rails_assets(:clobber)
        rails_assets(:precompile)
      end
    end

    def rails_assets(cmd)
      # rake is available in both rails 4 and 5. rails command only in 5
      command = "bundle exec rake assets:#{cmd} --trace"
      command = "RAILS_ENV=#{Jets.env} #{command}" unless Jets.env.development?
      sh("cd rack && #{command}")
    end

    # Rudimentary rails detection
    def rails?
      config_ru = "#{Jets.root}rack/config.ru"
      return false unless File.exist?(config_ru)
      !IO.readlines(config_ru).grep(/Rails.application/).empty?
    end

    # Cleans out non-cached files like code-*.zip in Jets.build_root
    # for a clean start. Also ensure that the /tmp/jets/project build root exists.
    #
    # Most files are kept around after the build process for inspection and
    # debugging. So we have to clean out the files. But we only want to clean out
    # some of the files.
    def clean_start
      Dir.glob("#{Jets.build_root}/code/code-*.zip").each { |f| FileUtils.rm_f(f) }
      FileUtils.mkdir_p(Jets.build_root) # /tmp/jets/demo
    end

    # Copy project into temporary directory. Do this so we can keep the project
    # directory untouched and we can also remove a bunch of unnecessary files like
    # logs before zipping it up.
    def copy_project
      headline "Copying current project directory to temporary build area: #{full(tmp_code)}"
      FileUtils.rm_rf(stage_area) # clear out from previous build
      FileUtils.mkdir_p(stage_area)
      FileUtils.rm_rf(full(tmp_code)) # remove current code folder
      move_node_modules(Jets.root, Jets.build_root)
      begin
        # puts "cp -r #{@full_project_path} #{full(tmp_code)}".colorize(:yellow) # uncomment to debug
        FileUtils.cp_r(@full_project_path, full(tmp_code))
      ensure
        move_node_modules(Jets.build_root, Jets.root) # move node_modules directory back
      end
    end

    # Move the node modules to the tmp build folder to speed up project copying.
    # A little bit risky because a ctrl-c in the middle of the project copying
    # results in a missing node_modules but user can easily rebuild that.
    #
    # Tesing shows 6.623413 vs 0.027754 speed improvement.
    def move_node_modules(source_folder, dest_folder)
      source = "#{source_folder}/node_modules"
      dest = "#{dest_folder}/node_modules"
      if File.exist?(source)
        FileUtils.mv(source, dest)
      end
    end

    # Bit hacky but this saves the user from accidentally forgetting to change this
    # when they deploy a jets project in development mode
    def reconfigure_development_webpacker
      return unless Jets.env.development?
      headline "Reconfiguring webpacker development settings for AWS Lambda."

      webpacker_yml = "#{full(tmp_code)}/config/webpacker.yml"
      return unless File.exist?(webpacker_yml)

      config = YAML.load_file(webpacker_yml)
      config["development"]["compile"] = false # force this to be false for deployment
      new_yaml = YAML.dump(config)
      IO.write(webpacker_yml, new_yaml)
    end

    def ruby_packager
      RubyPackager.new(tmp_code)
    end
    memoize :ruby_packager

    def rack_packager
      RackPackager.new("#{tmp_code}/rack")
    end
    memoize :rack_packager

    def package_ruby
      return if Jets.poly_only?

      ruby_packager.install
      reconfigure_rails # call here after full(tmp_code) is available
      rack_packager.install
      ruby_packager.finish # by this time we have a /tmp/jets/demo/stage/code/bundled
      rack_packager.finish
    end

    # TODO: Move logic into plugin instead
    def reconfigure_rails
      ReconfigureRails.new("#{full(tmp_code)}/rack").run
    end

    def cache_check_message
      if File.exist?("#{Jets.build_root}/cache")
        puts "The #{Jets.build_root}/cache folder exists. Incrementally re-building the jets using the cache.  To clear the cache: rm -rf #{Jets.build_root}/cache"
      end
    end

    def check_ruby_version
      unless ruby_version_supported?
        puts "You are using ruby version #{RUBY_VERSION} which is not supported by Jets."
        ruby_variant = Jets::RUBY_VERSION.split('.')[0..1].join('.') + '.x'
        abort("Jets uses ruby #{Jets::RUBY_VERSION}.  You should use a variant of ruby #{ruby_variant}".colorize(:red))
      end
    end

    def ruby_version_supported?
      pattern = /(\d+)\.(\d+)\.(\d+)/
      md = RUBY_VERSION.match(pattern)
      ruby = {major: md[1], minor: md[2]}
      md = Jets::RUBY_VERSION.match(pattern)
      jets = {major: md[1], minor: md[2]}

      ruby[:major] == jets[:major] && ruby[:minor] == jets[:minor]
    end

    # Group all the path settings together here
    def self.tmp_code
      Jets::Commands::Build.tmp_code
    end

    def tmp_code
      self.class.tmp_code
    end
  end
end
