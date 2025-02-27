#!/usr/bin/env ruby
$LOAD_PATH.unshift("#{File.dirname(__FILE__)}/../lib")

"""
Utility to launch OpenShift v3 instances
"""

require 'base64'
require 'cgi'
require 'commander'
require 'uri'
require 'yaml'
require 'json'

require 'collections'
require 'common'
require 'cucuhttp'

require 'launchers/cloud_helper'

module BushSlicer
  class EnvLauncherCli
    include Commander::Methods
    include Common::Helper
    include Common::CloudHelper

    def initialize
      always_trace!
    end

    def run
      program :name, 'EnvLauncherCli'
      program :version, '0.0.1'
      program :description, 'Tool to launch OpenShift Environment'

      #Commander::Runner.instance.default_command(:gui)
      default_command :template

      global_option('-c', '--config KEY',
                    "command specific:\n\t" <<
                    "* for OSE launcher selects config source\n\t" <<
                    "* for ec2_instance it selects custom setup script\n\t" <<
                    "* for template it specifies a file with YAML variables")
      global_option('-l', '--launched_instances_name_prefix PREFIX', 'prefix instance names; use string `{tag}` to have it replaced with MMDDb where MM in month, DD is day and b is build number; tag works only with PUDDLE_REPO')
      global_option('-d', '--user_data SPEC', "file containing user instances' data")
      global_option('-s', '--service_name SERVICE_NAME', 'service name to lookup in config')
      global_option('-i', '--image_name IMAGE', 'image to launch instance with')
      global_option('--it', '--instance_type TYPE', 'instance flavor to launch')

      command :template do |c|
        c.syntax = "#{File.basename __FILE__} template -l <instance name>"
        c.description = 'launch instances according to template'
        c.action do |args, options|
          say 'launching..'
          launch_template(**options.default)
        end
      end

      command :terminate do |c|
        c.syntax = "#{File.basename __FILE__} terminate <vminfo.yml>"
        c.description = "terminates instances based on vminfo file as generated by " \
          "the template launcher"
        c.action do |args, options|
          say 'terminating..'
          terminate(YAML.load_file args[0])
        end
      end

      command :ec2_instance do |c|
        c.syntax = "#{File.basename __FILE__} ec2_instance -l <instance name>"
        c.description = 'launch an instance with possibly an ansible playbook'
        c.action do |args, options|
          say 'launching..'
          options.service_name ||= :AWS
          options.service_name = options.service_name.to_sym

          launch_ec2_instance(options)
        end
      end

      command :fiddle do |c|
        c.syntax = "#{__FILE__} fiddle"
        c.description = 'enter a pry shell to play with API'
        c.action do |args, options|
          # you can try creating a host group like:
          # hosts.concat launch_host_group({num:1, roles:["master"]}, {name_prefix: "test-terminate-", service_name: "alicloud"}, existing_hosts: hosts)
          require 'pry'
          binding.pry
        end
      end

      run!
    end

    def get_dyn
      BushSlicer::Dynect.new()
    end

    # @param erb_vars [Hash, Binding] additional variales for ERB user_data
    #   processing
    # @param spec [String] user data specification
    # @return [String] user data to pass to instance
    def user_data(spec = nil, erb_vars = {})
      ## process user data
      spec ||= getenv('INSTANCES_USER_DATA')
      if spec
        case spec
        when URI.regexp
          url = URI.parse spec
          if url.scheme == "file"
            # to specify relative path, do like "file://p1/p2/p3"
            # to specify absolure path, do like "file:///p1/p2/p3"
            path = url.host ? File.join(url.host, url.path) : url.path
            user_data_string =
              File.read( expand_private_path(path, public_safe: true) )
          elsif url.scheme =~ /http/
            res = Http.get(url: spec)
            unless res[:success]
              raise "failed to get url: #{spec}"
            end
            user_data_string = res[:response]
          else
            raise "dunno how to handle scheme: #{url.scheme}"
          end

          if url.path.end_with? ".erb"
            url_options = CGI::parse url.query
            url_options = Collections.map_hash(url_options) { |k, v|
              # all single value URL params would be de-arrayified
              [ k, v.size == 1 ? v.first : v ]
            }
            erb = ERB.new(user_data_string)
            # options from url take precenece over launch options
            if Binding === erb_vars
              erb_binding = Common::BaseHelper.binding_from_hash(erb_vars.dup,
                                                                 **url_options)

            else
              erb_binding = Common::BaseHelper.binding_from_hash(**erb_vars,
                                                                 **url_options)
            end
            user_data_string = erb.result(erb_binding)
          end
        else
          # raw user data
          user_data_string = spec
        end

        # TODO: gzip data?
      else
        user_data_string = ""
      end

      return user_data_string
    end

    # process instance name prefix to generate an identity tag
    # e.g. "2015-11-10.2" => "11102"
    # If "latest" build is used, then we try to find it on server.
    def process_instance_name(name_prefix, puddle_repo = nil)
      puddle_re = '\d{4}-\d{2}-\d{2}\.\d+'
      return name_prefix.gsub("{tag}") {
        case puddle_repo
        when nil
          raise 'no pudde repo specified, cannot substitute ${tag}'
        when /#{puddle_re}/
          # $& is last match
          $&.gsub(/[-.]/,'')[4..-1]
        when %r{(?<=/)latest/}
          # $` is string before last match
          puddle_base = $`
          res = Http.get(url: puddle_base)
          raise "failed to get puddle base: #{puddle_base}" unless res[:success]
          puddles = []
          res[:response].scan(/href="(#{puddle_re})\/"/) { |m| puddles << m[0] }
          raise "strange puddle base: #{puddle_base}" if puddles.empty?
          puddles.map! { |p| p.gsub!(/[-.]/,'') }
          latest = puddles.map(&:to_str).map(&:to_i).max
          latest.to_s[4..-1]
        else
          raise "cannot find puddle base from url: #{puddle_repo}"
        end
      }
    end

    # path and basepath can be URLs but even if not, they should be URL encoded
    # @param details [Hash] a hash to put additional details about the read
    #   file; this is absolute location as string presently
    def readfile(path, basepath=nil, details: {})
      uri_parser = URI::RFC2396_Parser.new
      case path
      when %r{\Ahttps?://}
        details[:location] = path
        return Http.get(url: path, raise_on_error: true)[:response]
      when %r{\A/}
        details[:location] = path
        return File.read(uri_parser.unescape(path))
      else
        if basepath
          with_base = join_paths_or_urls(basepath, path)
          return readfile(with_base, details: details)
        else
          details[:location] = expand_path(uri_parser.unescape(path))
          return File.read details[:location]
        end
      end
    end

    private def basename(path_or_url)
      File.basename(URI.parse(path_or_url).path)
    end

    # @param path_or_url [String] the URL or PATH we want to get dirname of
    # @return [String] base path or URL
    private def dirname_path_or_url(path_or_url)
      dirname = File.dirname path_or_url
      return dirname == "." ? nil : dirname
    end

    # @param base_path_or_url [String]
    # @param relative_path_or_url [String]
    # @return [String] joined and normalized
    private def join_paths_or_urls(base_path_or_url, relative_path_or_url)
      joined = File.join(base_path_or_url, relative_path_or_url)
      # remove any `..` and `.` path elements
      joined.gsub!(%r{/\./}, "/")
      while joined.gsub!(%r{/[^/]+/\.\./}, "/") do end
      return joined
    end

    def localize(path, basepath=nil)
      case path
      when %r{\Ahttps?://}
        filename = basename(path)
        unless filename =~ /\A[-a-zA-Z0-9._]+\z/
          raise "bad filename '#{filename}' for URL: #{path}"
        end
        filename = Host.localhost.absolutize(filename)
        File.write(filename, Http.get(url: path,
                                      raise_on_error: true)[:response])
        return filename
      when %r{\A/}
        return path
      else
        if basepath
          return localize(join_paths_or_urls(basepath, path))
        else
          return expand_path(path)
        end
      end
    end

    def merged_launch_opts(common, overrides)
      common ||= {}
      overrides ||= {}
      service_name = overrides[:service_name] || common[:service_name]
      if service_name
        service_name = service_name.to_sym
      else
        raise "no service name specified for host launch options"
      end

      common_launch_opts = common[service_name] || {}
      overrides_launch_opts = overrides[service_name] || {}
      return service_name,
        Collections.deep_merge(common_launch_opts, overrides_launch_opts)
    end

    def gen_ose3_timed_random_component
      return Time.now.strftime("%m%dos3") << "-" << rand_str(3, :dns)
    end

    def dns_component
      @dns_component ||= gen_ose3_timed_random_component
    end

    def dns_component=(value)
      if value.end_with?(".") || value =~ /(?<=\w\.|^)(?:\d{4}|fixed)-[^.]+$/
        @dns_component = value
        logger.warn "User specified DNS component: #{value}"
      else
        raise "got '#{value}' but allowed only FQDN ending with dot or " \
          "a relative subdomain ending with a fixed or a timed subdomain " \
          "component; i.e. match /(?<=\\w\\.|^)(?:\\d{4}|fixed)-[^.]+$/"
      end
    end

    # for an array of strings ending on a num, returns first free index for a
    #   prefix such that adding "#{prefix}#{num}" to the array will not dup
    def next_index_for_prefix(prefix:, name_list:)
      return 1 unless name_list
      pattern = /^#{Regexp.escape(prefix.tr(?-, ?_)).gsub(?_,"[-_]")}\d+$/
      max_index = name_list.select { |name|
        name =~ pattern
      }.map { |n|
        Integer(n[prefix.size..-1], 10)
      }.max
      max_index ? max_index + 1 : 1
    end

    # generates an array of non-duplicate "#{string}#{num}" based on params
    def generate_numbered_names(existing_names: nil, prefix:, roles:, num:)
      full_name_prefix = "#{prefix}#{roles.join("-")}-"
      index_offset = next_index_for_prefix(prefix: full_name_prefix,
                                           name_list: existing_names)
      host_names = num.times.map { |i|
        "#{full_name_prefix}#{(i + index_offset)}"
      }

      # limit length according to user settings
      if host_names.any? {|n| n.size > (conf[:max_instance_name_length] || 63)}
        short_roles ||= roles.map(&:chars).map(&:first).join
        new_full_prefix ||= "#{prefix}#{short_roles}-"
        new_index_offset = next_index_for_prefix(prefix: new_full_prefix,
                                                 name_list: existing_names)
        # keepindex continuity if possible
        new_index_offset = [index_offset, new_index_offset].max
        host_names = num.times.map { |i|
          "#{new_full_prefix}#{(i + new_index_offset)}"
        }
      end

      return host_names
    end

    # This method will:
    # - merge common launch opts with host group launch opts
    # - process user-data so it is passed to IaaSes as they expect
    # - pass merged launch opts, user-data and host_opts to
    #     IaaS#create_instances in the proper way
    # The meaning of launch opts and what can be set by it
    #   varies between service providers. See #create_instances of the
    #   different IaaSes understanding.
    # @return [Array<Host>]
    def launch_host_group(host_group, common_launch_opts,
                          user_data_vars: {}, existing_hosts: nil)

      host_names = generate_numbered_names(
        prefix: common_launch_opts[:name_prefix],
        existing_names: existing_hosts&.map {|h| h[:cloud_instance_name]},
        roles: host_group[:roles],
        num: host_group[:num]
      )

      # get launch instances config
      service_name, launch_opts = merged_launch_opts(common_launch_opts, host_group[:launch_opts])

      # get user data
      if launch_opts[:user_data]
        user_data_string = user_data(launch_opts[:user_data], user_data_vars)
      else
        user_data_string = ""
      end
      launch_opts.delete(:user_data)

      iaas = iaas_by_service(service_name)
      launched = case iaas
      when BushSlicer::Amz_EC2
        launch_opts[:user_data] = Base64.encode64(user_data_string)
        host_opts = launch_opts.delete(:host_opts) || {}
        res = iaas.launch_instances(tag_name: host_names,
                                    image: launch_opts.delete(:image),
                                    host_opts: host_opts,
                                    create_opts: launch_opts)
      when BushSlicer::Azure
        unless user_data_string.empty?
          raise "RHEL does not support user-data in Azure yet"
        end
        res = iaas.create_instances(host_names, **launch_opts)
      when BushSlicer::Alicloud
        logger.debug "Creating a host group in Alibaba Cloud"
        host_opts = launch_opts.delete(:host_opts) || {}
        launch_opts = Collections.map_hash(launch_opts) { |k, v|
          [k.to_s, v]
        }.to_hash
        unless user_data_string.empty?
          launch_opts["UserData"] = user_data_string
        end

        prefix = host_names.first.gsub(/\d+$/, "")
        num = Integer(host_names.first[prefix.length..-1], 10)
        if num == 1
          launch_opts["InstanceName"] = prefix
        else
          idx = (2..100).find { |i|
            existing_hosts.none? { |h|
              h[:cloud_instance_name].start_with? "#{prefix}#{i}-"
            }
          }
          launch_opts["InstanceName"] = "#{prefix}#{idx}-"
        end

        if host_names.size == 1
          launch_opts["InstanceName"] = "#{launch_opts["InstanceName"]}001"
        else
          launch_opts["Amount"] = host_names.size
        end
        launch_opts["UniqueSuffix"] = true
        logger.debug("Launch Options: #{launch_opts}")
        logger.debug("Host Options: #{host_opts}")
        res = iaas.create_instances(
          create_opts: launch_opts.dup,
          host_opts: host_opts
        )
      when BushSlicer::OpenStack
        create_opts = {}
        res = iaas.launch_instances(
          names: host_names,
          user_data: Base64.encode64(user_data_string),
          **launch_opts
        )
      when BushSlicer::GCE
        res = iaas.create_instances(host_names, user_data: user_data_string,
                                    **launch_opts )
      when BushSlicer::VSphere
        if user_data_string && !user_data_string.empty?
          logger.warn "user-data not implemented for VSphere yet"
        end
        host_opts = launch_opts.delete(:host_opts) || {}
        res = iaas.create_instances(host_names,
                                    host_opts: host_opts,
                                    create_opts: launch_opts)
      else
        raise "Unknown IaaS class #{iaas.class}."
      end

      # set hostnames if cloud has broken defaults
      fix_hostnames = conf[:services, service_name, :fix_hostnames]
      launched = launched.map(&:last)
      launched.each do |host|
        host[:fix_hostnames] = fix_hostnames
        host[:cloud_service_name] = service_name
        # This property will contain only whatever opts are set for launching
        #   this instance in the launch template. One still needs to have the
        #   same global config as used during launch command to get the opts
        #   that were not overridden in the launch template.
        host[:cloud_launch_opts] = launch_opts
        host.roles.concat host_group[:roles]
      end

      return launched
    end

    def launcher_binding
      binding
    end

    # symbolize keys in launch templates
    # @param template [Hash]
    def normalize_template(template)
      template = Collections.deep_hash_symkeys template
      template[:hosts][:list].map! {|hg| Collections.deep_hash_symkeys hg}
      # insert helper reference name to help implicit node creation at start
      template[:hosts][:list].each {|hg| hg[:ref] ||= rand_str(5, :dns)}

      template[:install_sequence].map! {|is| Collections.deep_hash_symkeys is}
      template[:install_sequence].each do |task|
        if task[:type] == "launch_host_groups" && Array === task[:list]
          task[:list].map! {|hg| Collections.deep_hash_symkeys hg}
        end
      end
      return template
    rescue
      logger.plain "failed to normalize:\n#{template.to_yaml}" rescue nil
      raise
    end

    def task_env_process(env, evalbinding, basepath)
      case env
      when nil
        return env
      when Hash
        # do nothing
      when /^expr:/
        env = evalbinding.eval(env.sub(/^expr:/, ""))
      when /^file:.*\.rb$/
        file = env.sub(/^file:/, "")
        env = evalbinding.eval(readfile(file, basepath), file)
      else
        raise "unknown env specification: #{env}"
      end

      return Collections.deep_hash_strkeys env
    end

    def run_ansible_playbook(playbook, inventory, extra_vars: nil, env: nil, retries: 1)
      env ||= {}
      env["ANSIBLE_FORCE_COLOR"] = "true"
      env["ANSIBLE_CALLBACK_WHITELIST"] = 'profile_tasks'

      case extra_vars
      when nil
        extra_vars = []
      when Hash
        extra_vars = ["-e", extra_vars.to_json]
      when Array
        extra_vars = extra_vars.each_with_object([]) { |i, arr| arr << "-e" << i }
      when String
        extra_vars = ["-e", extra_vars]
      else
        raise "bad extra_vars value #{extra_vars.inspect}"
      end

      retries.times do |attempt|
        id_str = (attempt == 0 ? ': ' : " (try #{attempt + 1}): ") + playbook
        say "############ ANSIBLE RUN#{id_str} ############################"
        res = Host.localhost.exec(
          'ansible-playbook', '-v', '-i', inventory, *extra_vars,
          playbook,
          env: env, single: true, stderr: :stdout, stdout: STDOUT, timeout: 36000
        )
        say "############ ANSIBLE END#{id_str} ############################"
        if res[:success]
          break
        elsif attempt >= retries - 1
          raise "ansible failed execution, see logs" unless res[:success]
        end
      end
    end

    # performs an installation task
    def installation_task(task, template:, erb_binding:, template_dir: nil)
      case task[:type]
      when "force_domain"
        self.dns_component = task[:name]
      when "dns_hostnames"
        begin
          erb_binding.local_variable_get(:hosts).each do |host|
            if !host.has_hostname?
              dns_record = host[:cloud_instance_name] || rand_str(5, :dns)
              dns_record = dns_record.gsub("_","-")
              dns_record = "#{dns_record}.#{dns_component}"
              host.update_hostname iaas_by_service("AWS-CI").create_a_records(dns_record, [host.ip])
              host[:fix_hostnames] = true
            end
          end
        end
      when "dns_internal_ips"
        if erb_binding.local_variable_defined?(:internal_subdomain)
          int_subdomain = erb_binding.local_variable_get(:internal_subdomain)
        else
          int_subdomain = task[:subdomain] || "int"
          int_subdomain += ".#{dns_component}"
        end
        begin
          aws_iaas = iaas_by_service("AWS-CI")
          base_domain = aws_iaas.default_zone.sub(/[.]$/,"")
          int_subdomain_fqdn = int_subdomain.end_with?('.') ? int_subdomain[0..-2] : "#{int_subdomain}.#{base_domain}"
          erb_binding.local_variable_set(:internal_subdomain, int_subdomain_fqdn)
          erb_binding.local_variable_get(:hosts).each do |host|
            dns_record = host[:cloud_instance_name] || rand_str(5, :dns)
            dns_record = dns_record.gsub("_","-")
            dns_record = "#{dns_record}.#{int_subdomain}"
            host[:internal_fqdn] = aws_iaas.create_a_records(dns_record, [host.local_ip])
            logger.info "Creating '#{dns_record}' record for: internal IP " \
              "#{host.local_ip} of host #{host.hostname}"
          end
        end
      when "a_dns"
        begin
          ips = task[:ips]

          unless ips && !ips.empty?
            raise 'You need to specify IPs for the `a_dns` task.'
          end

          dns_record = "#{task[:prefix]}.#{dns_component}"
          logger.info "Creating '#{dns_record}' record for: #{ips.join(?,)}"
          fqdn = iaas_by_service("AWS-CI").create_a_records(dns_record, ips)
          if task[:store_in]
            erb_binding.local_variable_set task[:store_in].to_sym, fqdn
          end
        end
      when "wildcard_dns"
        ips = []

        if task[:roles]
          hosts = erb_binding.local_variable_get(:hosts)
          ips.concat(hosts.select{|h| h.has_any_role? task[:roles]}.map(&:ip))
        end
        if task[:ips]
          ips.concat task[:ips]
        end

        a_task = {
          type: "a_dns",
          prefix: "*.apps",
          ips: ips,
          store_in: task[:store_in]
        }
        installation_task( a_task,
                           template: template,
                           erb_binding: erb_binding,
                           template_dir: template_dir )
      when "shell_command"
        exec_opts = {
          single: true,
          stderr: :stdout, stdout: STDOUT, stdin: task[:stdin],
          timeout: 36000
        }
        if task[:env]
          exec_opts[:env] = task_env_process(task[:env], erb_binding, template_dir)
        end
        # if :cmd is passed as a string, then it will run unmodified in shell
        # if :cmd is multi-element array, it will run without shell
        # if :cmd is one-element array, we need special care to avoid shell
        if Array === task[:cmd] && task[:cmd].size == 1
          res = Host.localhost.exec([task[:cmd].first, task[:cmd].first],
                                                                **exec_opts)
        elsif Array === task[:cmd]
          res = Host.localhost.exec(*task[:cmd], **exec_opts)
        else
          res = Host.localhost.exec(task[:cmd], **exec_opts)
        end
        unless res[:success]
          raise "shell command failed execution, see logs"
        end
      when "ruby"
        if task[:file]
          ruby_file_details = {}
          erb_binding.eval(readfile(task[:file], template_dir, details: ruby_file_details), ruby_file_details[:location])
        elsif task[:expression]
          erb_binding.eval(task[:expression], "expression_in_template")
        end
      when "playbook"
        inventory_erb = ERB.new(
          readfile(task[:inventory], template_dir),
          nil
        )
        inventory_erb.filename = task[:inventory]
        inventory_str = inventory_erb.result(erb_binding)
        inventory = Host.localhost.absolutize basename(task[:inventory])
        puts "Ansible inventory #{File.basename inventory}:\n#{inventory_str}"
        File.write(inventory, inventory_str)
        run_ansible_playbook(
          localize(task[:playbook]), inventory,
          extra_vars: task[:extra_vars],
          retries: (task[:retries] || 1),
          env: task_env_process(task[:env], erb_binding, template_dir)
        )
      when "launch_host_groups"
        existing_hosts = erb_binding.local_variable_get(:hosts)
        hosts = []
        hosts_spec = template[:hosts]
        common_launch_opts = hosts_spec[:common_launch_opts]

        task[:list].each do |req|
          host_group = hosts_spec[:list].find {|hg| hg[:ref] == req[:ref]}
          if host_group
            hosts.concat launch_host_group(
              host_group.merge({num: req[:num]}),
              common_launch_opts,
              user_data_vars: erb_binding,
              existing_hosts: existing_hosts + hosts
            )
          else
            raise "no host group #{req[:ref].inspect} defined"
          end
        end

        # wait each host to become accessible
        existing_hosts.concat hosts
        vm_accessible_timeout = conf[:vm_accessible_timeout] || 600
        hosts.each {|h| h.wait_to_become_accessible(vm_accessible_timeout)}
      else
        raise "unsupported installation task: '#{task[:type]}'"
      end
    end

    # @param config [String] an YAML file to read variables from
    # @param launched_instances_name_prefix [String]
    def launch_template(config:, launched_instances_name_prefix:)
      hosts = []
      terminate_spec = {}
      file_details = {}

      # Export configuration's block of environment variables to running environment context
      if Hash === conf[:global, :"install-envvars"]
        conf[:global, :"install-envvars"].each do |key, val|
          if ENV.key?(key.to_s)
            say "WARNING: value from environment variable #{key.to_s} takes precedence over value in 'install-envvars' configuration"
          else
            ENV[key.to_s] = val
          end
        end
      end

      vars = YAML.load(readfile(config, details: file_details))
      if ENV["LAUNCHER_VARS"] && !ENV["LAUNCHER_VARS"].strip.empty?
        launcher_vars = YAML.load ENV["LAUNCHER_VARS"]
        if Hash === launcher_vars
          Collections.deep_merge!(vars, launcher_vars)
        else
          raise "LAUNCHER_VARS not a mapping but #{launcher_vars.inspect}"
        end
      end
      vars = Collections.deep_hash_symkeys vars
      vars[:instances_name_prefix] = launched_instances_name_prefix
      vars[:variables_file] = config
      vars[:hosts] = hosts
      vars[:terminate_spec] = terminate_spec
      raise "specify 'template' in variables" unless vars[:template]

      # this dir can be a URL or a PATH
      config_dir = dirname_path_or_url(file_details[:location])
      template = ERB.new(
        readfile(vars[:template], config_dir, details: file_details),
        nil
      )
      template.filename = file_details[:location]
      erb_binding = Common::BaseHelper.binding_from_hash(launcher_binding,
                                                         **vars)
      template_dir = dirname_path_or_url(file_details[:location])

      # define convenience include methods
      # defined variables here do not become available in caller template though
      # see https://stackoverflow.com/questions/53886078
      erb_binding.local_variable_set :include_erb, lambda { |path, indent=0|
        t = ERB.new(
          readfile(path, template_dir), nil, nil, rand_str(10, :ruby_variable)
        )
        t.filename = path
        t.result(erb_binding).gsub(/^/, " "*indent)
      }
      erb_binding.local_variable_set :include_ruby, lambda { |path|
        eval(readfile(path, template_dir), erb_binding, path)&.to_json
      }

      # finally execute and normalize template
      template_result = template.result(erb_binding)
      puts "Loading Template:\n#{template_result}"
      begin
        template = YAML.load(template_result)
      rescue
        logger.info "Failed to parse YAML of:\n#{template_result}" rescue nil
        raise
      end
      template = normalize_template(template)

      ## implicit launch of hosts
      implicit_launch_task = { type: "launch_host_groups", list: [] }
      template[:hosts][:list].each do |host_group|
        if host_group[:num] && host_group[:num] > 0
          implicit_launch_task[:list] << {ref: host_group[:ref], num: host_group[:num]}
        end
      end
      unless implicit_launch_task[:list].empty?
        template[:install_sequence].unshift implicit_launch_task
      end

      ## perform provisioning steps
      org_term = Signal.trap('TERM') { raise "Received SIGTERM during installation." }
      org_int = Signal.trap('INT') { raise "Received SIGINT during installation." }
      template[:install_sequence].each do |task|
        installation_task(
          task,
          erb_binding: erb_binding,
          template: template,
          template_dir: template_dir
        )
      end

      ## help users persist home info
      hosts_spec = hosts.map{ |h|
        "#{h[:flags]}#{h.hostname}:#{h.roles.join(':')}"
      }.join(',')
      logger.info "HOSTS SPECIFICATION: #{hosts_spec}"
      host_spec_out = ENV["BUSHSLICER_HOSTS_SPEC_FILE"]
      if host_spec_out && !File.exist?(host_spec_out)
        begin
          File.write(host_spec_out, hosts_spec)
        rescue => e
          logger.error("could not save host specification: #{e.inspect}")
        end
      end
    ensure
      Signal.trap('TERM', org_term)
      Signal.trap('INT', org_int)
      # create a file with launched instances information
      # TODO: change VMINFO to better name here and in Jenkins jobs
      terminate_out = ENV["BUSHSLICER_VMINFO_YAML"] || "vminfo.yml"
      unless terminate_out.empty?
        vminfo = hosts.
          group_by { |h| h[:cloud_service_name] }.
          select { |service_name, hosts| service_name }.
          map { |service_name, hosts|
            [
              service_name, hosts.map { |h|
                {
                  name: h[:cloud_instance_name],
                  launch_opts: h[:cloud_launch_opts]
                }
              }
            ]
          }.
          to_h
        terminate_spec.merge! vminfo
        if defined?(dns_component) and (not dns_component.empty?)
          terminate_spec.merge!({
            dns_component:  dns_component
          })
        end
        begin
          File.write(terminate_out, terminate_spec.to_yaml)
        rescue => e
          logger.error("could not save vminfo YAML: #{e.inspect}")
        end
      end
    end

    def launch_ec2_instance(options)
      image = options.image_name || getenv('CLOUD_IMAGE_NAME')
      image = nil if image && image.empty?
      instance_name = options.launched_instances_name_prefix
      options.instance_type ||= getenv('CLOUD_INSTANCE_TYPE')
      if options.instance_type && !options.instance_type.empty?
        create_opts[:instance_type] = options.instance_type
      end
      if instance_name.nil? || instance_name.empty?
        raise "you must specify instance name with -l"
      end
      user_data = user_data(options.user_data)
      amz = Amz_EC2.new(service_name: options.service_name)
      res = amz.launch_instances(tag_name: [instance_name], image: image,
                           create_opts: {user_data: Base64.encode64(user_data)},
                           wait_accessible: true)

      instance, host = res[0]
      unless host.kind_of? BushSlicer::Host
        raise "bad return value: #{host.inspect}"
      end

      ## setup instance if there is a setup script
      setup = options.config
      unless setup
        # see if we have a setup script in config based on instance name
        scripts = conf[:services, options.service_name, :setup_scripts]
        if scripts
          image_name = instance.image.name
          setup = scripts.find { |e|
            image_name =~ e[:re]
          }
          setup = setup[:script] if setup
        end
      end
      if setup
        url = URI.parse setup
        path = expand_private_path(url.path, public_safe: true)
        query = url.query
        params = query ? CGI::parse(query) : {}
        Collections.map_hash!(params) { |k, v| [k, v.last] }
        setup_binding = Common::BaseHelper.binding_from_hash(binding, params)
        eval(File.read(path), setup_binding, path)
      end
    end

    # @param vminfo [Hash] as generated by the template launcher - for
    #   each service name it would list launch options used to start instances
    def terminate(vminfo)
      vminfo.each do |target, spec|
        case target
        when /^template_/
          # construct variables file with updated template
          vars = YAML.load(readfile(spec[:config]))
          vars_org_dir = dirname_path_or_url(spec[:config])
          unless vars_org_dir =~ %r{^\w+://}
            vars_org_dir = File.absolute_path(vars_org_dir)
          end
          template_org_dir = dirname_path_or_url(
            join_paths_or_urls(vars_org_dir, vars["template"])
          )
          vars["template"] = join_paths_or_urls(
            template_org_dir, spec[:template]
          )
          vars["command_terminate"] = true
          vars_file = Tempfile.new("vars_file_", Host.localhost.workdir)
          vars_file.write(vars.to_yaml)
          vars_file.close
          ENV["BUSHSLICER_VMINFO_YAML"] = "" # avoid initializing the file
          # we launch a template to clean-up whatever it is
          launch_template(
            config: vars_file.path,
            launched_instances_name_prefix: spec[:name_prefix]
          )
        when /^dns_component/
          # remove route53, which should at the end of the yaml
          if (not spec.nil?) and (not spec.empty?)
            begin
              aws_iaas = iaas_by_service("AWS-CI")
              dns_record_regexp = Regexp.new(/#{spec}/)
              aws_iaas.delete_resource_records_re(dns_record_regexp)
            rescue
              logger.info("Unable to delete DNS records matching #{spec}")
            end
          end
        else
          # target assumed to be a service name
          iaas = iaas_by_service(target)
          iaas.terminate_by_launch_opts(spec)
        end
      end
    end

    # return name of currently executed command
    # def active_command
    #   Commander::Runner.instance.active_command.name
    # end
  end
end

if __FILE__ == $0
  BushSlicer::EnvLauncherCli.new.run
end
