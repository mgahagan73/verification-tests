#!/usr/bin/env ruby
# frozen_string_literal: true

"""
Utility to enable some PolarShift operations via CLI
"""

require 'commander'
require 'pathname'

require_relative 'common/load_path'

require 'common'
require "gherkin_parse"

require_relative "stompbus/stompbus"

module BushSlicer
  class PolarShiftCli
    include Commander::Methods
    include Common::Helper

    TCMS_RELEVANT_TAGS = ["admin", "destructive", "vpn", "smoke"].freeze

    def initialize
      always_trace!
    end

    def run
      program :name, 'PolarShift CLI'
      program :version, '0.0.1'
      program :description, 'Tool to enable some PolarShift operations via CLI'

      #Commander::Runner.instance.default_command(:gui)
      default_command :help

      global_option('-p', '--project ID', 'Project ID to use')
      global_option('--polarshift URL', 'PolarShift URL')

      command :fiddle do |c|
        c.syntax = "#{__FILE__} fiddle"
        c.description = 'enter a pry shell to play with API'
        c.action do |args, options|
          setup_global_opts(options)
          require 'pry'
          binding.pry
        end
      end

      command :"update-automation" do |c|
        c.syntax = "#{$0} update-automation [options]"
        c.description = 'Update test case automation related fields.'
        c.option('--no-wait', "Wait on message bus for operation to complete.")
        c.action do |args, options|
          setup_global_opts(options)
          if args.empty?
            raise "please add Test Case IDs in the command line"
            exit false
          end

          project_id = project

          parser = GherkinParse.new
          cases_loc = parser.locations_for *args
          cases_spec = parser.spec_for cases_loc
          print_fileno(cases_loc)

          updates = generate_case_updates(project_id, cases_spec)

          # print what we are going to do to user
          updates.each do |c, updates|
            puts "Automation script field for #{HighLine.color c, :bold}:\n"
            updates.each do |field, update|
              puts "#{HighLine.color(field.to_s.upcase, :magenta, :bold)}: #{HighLine.color(update.strip, :green)}"
            end
            puts "======================================"
          end

          ## prepare user/password to the bus early to catch message
          if options.no_wait.nil?
            begin
              bus_client = msgbus.new_client
            rescue => e
              options.no_wait = true
              logger.warn "Connection to message bus failed, progress won't " \
                "be tracked"
              logger.info e
            end
          end

          puts "Updating cases: #{updates.keys.join(", ")}.."
          res = polarshift.
            update_test_case_custom_fields(project_id, updates)
          if res[:success]
            filter = JSON.load(res[:response])["import_msg_bus_filter"]
            unless filter && !filter.empty?
              puts "unknown importer response:\n#{res[:response]}"
              exit false
            end
            if options.no_wait.nil?
              puts "waiting for a bus message with selector: #{filter}"
              message = nil
              bus_client.subscribe(msgbus.default_queue, selector:filter) do |m|
                message = m
                bus_client.close
              end
              bus_client.join
              puts STOMPBus.msg_to_str(message)
            end
          else
            puts "HTTP Status: #{res[:exitcode]}, Response:\n#{res[:response]}"
            exit false
          end
        end
      end

      command :"create-run" do |c|
        c.syntax = "#{$0} create-run [options]"
        c.description = "Create a new test run\n\te.g. " \
          'tools/polarshift.rb create-run -f ../polarshift/req.json'
        c.option('-f', "--file FILE", "YAML file with create parameters.")
        c.option('--no-wait', "Skip waiting on message bus for operation to complete.")
        c.action do |args, options|
          setup_global_opts(options)

          unless options.file
            raise "Please specify file to read test run create options from"
          end

          unless File.exist? options.file
            raise "specified input file does not exist: #{options.file}"
          end

          params = YAML.load(File.read(options.file))
          Collections.hash_symkeys! params

          ## prepare user/password to the bus early to catch message
          if options.no_wait.nil?
            begin
              bus_client = msgbus.new_client
            rescue => e
              options.no_wait = true
              logger.warn "Connection to message bus failed, progress won't " \
                "be tracked"
              logger.info e
            end
          end

          pr = polarshift.create_run_smart(project_id: project, **params)

          quoted_run_id = "'" + pr[:run_id] + "'"

          puts "test run id: #{HighLine.color(quoted_run_id, :bright_blue)}"
          # TODO: move waiting using HTTP to Polarshift, msg goes before we can subscribe
          filter = pr[:import_filter]
          if options.no_wait.nil?
            puts "waiting for a bus message with selector: #{filter}"
            message = nil
            bus_client.subscribe(msgbus.default_queue, selector: filter) do |m|
              message = m
              bus_client.close
            end
            bus_client.join
            puts STOMPBus.msg_to_str(message)
          end
        end
      end
      
      command :"get-run" do |c|
        c.syntax = "#{$0} get-run [options]"
        c.description = "retrieve a test run Polarion\n\t" \
          "e.g. tools/polarshift.rb get-run my_run_id"
        c.option('-o', "--output FILE", "Write query result to file in JSON format")
        c.action do |args, options|
          setup_global_opts(options)

          if args.size != 1
            raise "command expects exactly one parameter being the test run id"
          end

          test_run_id = args.first
          query_result = polarshift.get_run_smart(project, test_run_id)
          result = query_result
          pp(result)
          if options.output
            File.write(options.output, JSON.pretty_generate(result))
          end
        end
      end

      command :"query-cases" do |c|
        c.syntax = "#{$0} query-cases [options]"
        c.description = "run query for test cases\n\te.g. " \
          'tools/polarshift.rb query-cases -f ../polarshift/req.json'
        c.option('-f', "--file FILE", "YAML file with create parameters.")
        c.option('-o', "--output FILE", "Write query result to file.")
        c.action do |args, options|
          setup_global_opts(options)

          unless options.file
            raise "Please specify file to read test run create options from"
          end

          unless File.exist? options.file
            raise "specified input file does not exist: #{options.file}"
          end

          params = YAML.load(File.read(options.file))
          Collections.hash_symkeys! params

          pr = polarshift.query_test_cases_smart(project_id: project, **params)

          cases = pr[:list]

          puts "#{HighLine.color(cases.join("\n"), :bright_blue)}"
          if options.output
            File.write options.output, cases.join("\n")
          end
        end
      end

      command :"push-run" do |c|
        c.syntax = "#{$0} push-run [options]"
        c.description = "Pushes test run results from cache to backend\n\t" \
          "e.g. tools/polarshift.rb push-run -p my_project my_run_id"
        c.option("--force", "Force push even without changes since last push.")
        c.action do |args, options|
          setup_global_opts(options)

          if args.size != 1
            raise "command expects exactly one parameter being the test run id"
            exit false
          end

          res = polarshift.push_test_run_results(project, args.first,
                                                 force: !!options.force)
          if res[:success]
            puts res[:parsed]["description"]
          else
            puts "HTTP Status: #{res[:exitcode]}, Response:\n#{res[:response]}"
            exit false
          end
        end
      end

      run!
    end

    # @param project [String] project id
    # @param cases_spec [Hash<String, Hash>] structure like:
    #   case_id_1:
    #     scenario: scenario name
    #     file: file name relative to cucumber dir
    #     args:
    #       some: arg if any
    #   case_id_2: ...
    def generate_case_updates(project, cases_spec)
      updates = normalize_tags(project, cases_spec).map do |case_id, spec|
        tags = spec.delete("tags")
        update = {
          caseautomation: "automated",
          automation_script: {"cucushift" => spec}.to_yaml
        }
        update[:tags] = tags if tags
        [ case_id, update ]
      end
      return Hash[updates]
    end

    def print_fileno(locations)
      puts "To execute listed test cases on command line, use this filter:"
      home = Pathname.new(::BushSlicer::HOME)
      puts HighLine.color(
        locations.
          map(&:last).
          map {|c| c.join(?:)}.
          map {|c| Pathname.new(c).relative_path_from(home).to_s}.
          join(" "),
        :bright_blue
      )
    end

    # Allows you to modify automation fields for test cases
    # @param project [String]
    # @param case_ids [Array<String>]
    # @yield [case_spec, test_case] the block should return updates wanted for
    #   each test case, e.g. `{"tags": "tag1 tag2 tag3"}`
    def sed_automation(project, case_ids)
      puts "Getting cases: #{case_ids.join(", ")}.."
      polarshift.refresh_cases_wait(project, case_ids)
      cases_raw = polarshift.get_cases_smart(project, case_ids)

      updates = {}
      cases_raw.each do |tc_raw|
        tc = PolarShift::TestCase.new(tc_raw, polarshift)
        update = yield tc_raw, tc
        if update && !update.empty?
          updates[tc.id] = update
        end
      end


      puts "Updating cases: #{updates.keys.join(", ")}.."

      require 'pry'; binding.pry
      res = polarshift.
        update_test_case_custom_fields(project, updates)
      if res[:success]
        filter = JSON.load(res[:response])["import_msg_bus_filter"]
        unless filter && !filter.empty?
          puts "unknown importer response:\n#{res[:response]}"
          raise res[:response]
        end
      else
        puts "HTTP Status: #{res[:exitcode]}, Response:\n#{res[:response]}"
        raise res[:response]
      end
    end

    # @return [Array<String, Array>] same as [GherkinParse#cases_spec] but
    #   we do not convert to Hash as it is not needed
    # @see #generate_case_updates for parameter description
    def normalize_tags(project, cases_spec)
      casetags = {}
      cases_spec.each do |case_id, spec|
        tags = spec.delete("tags")
        if tags && !tags.empty?
          raise "bad tag format: #{tags}" unless Array === tags
          tags.each do |tag|
            raise "bad tag value: #{tag.inspect}" unless String === tag
          end
          casetags[case_id] = tags
        else
          casetags[case_id] = []
        end
      end

      puts "Getting cases: #{casetags.keys.join(", ")}.."
      polarshift.refresh_cases_wait(project, casetags.keys)
      cases_raw = polarshift.get_cases_smart(project, casetags.keys)

      cases = cases_raw.map { |c| PolarShift::TestCase.new(c, polarshift) }

      cases.each do |tcms_case|
        final_tags = casetags[tcms_case.id] & TCMS_RELEVANT_TAGS
        final_tags.concat(tcms_case.tags - TCMS_RELEVANT_TAGS)
        if final_tags != tcms_case.tags
          cases_spec[tcms_case.id]["tags"] = final_tags.join(" ")
        end
      end

      return cases_spec
    end

    def project
      polarshift.default_project
    end

    def polarshift
      @polarshift ||= PolarShift::Request.new(**opts)
    end

    def msgbus
      @msgbus ||= STOMPBus.new
    end

    def opts
      @opts || raise('please first call `setup_global_opts(options)`')
    end

    # @param options [Ostruct] options as processed by Commander
    def setup_global_opts(options)
      opts = options.default
      if opts[:project]
        opts[:manager] = { project: opts.delete(:project) }
      end
      if opts[:polarshift]
        opts[:base_url] = opts.delete(:polarshift)
      end
      @opts = opts
    end
  end
end

if __FILE__ == $0
  BushSlicer::PolarShiftCli.new.run
end
