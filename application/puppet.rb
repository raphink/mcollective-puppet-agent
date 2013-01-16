class MCollective::Application::Puppet<MCollective::Application
  description "Schedule runs, enable, disable and interrogate the Puppet Agent"

  usage <<-END_OF_USAGE
mco puppet [OPTIONS] [FILTERS] <ACTION> [CONCURRENCY|MESSAGE]
Usage: mco puppet <count|enable|status|summary>
Usage: mco puppet disable [message]
Usage: mco puppet runonce [PUPPET OPTIONS]

The ACTION can be one of the following:

    count   - return a total count of running, enabled, and disabled nodes
    enable  - enable the Puppet Agent if it was previously disabled
    disable - disable the Puppet Agent preventing catalog from being applied
    runall  - invoke a puppet run on matching nodes, making sure to only run
              CONCURRENCY nodes at a time
    runonce - invoke a Puppet run on matching nodes
    status  - shows a short summary about each Puppet Agent status
    summary - shows resource and run time summaries
END_OF_USAGE

  option :force,
         :arguments   => ["--force"],
         :description => "Bypass splay options when running",
         :type        => :bool

  option :server,
         :arguments   => ["--server SERVER"],
         :description => "Connect to a specific server or port",
         :type        => String

  option :tag,
         :arguments   => ["--tag TAG"],
         :description => "Restrict the run to specific tags",
         :type        => :array

  option :noop,
         :arguments   => ["--noop"],
         :description => "Do a noop run",
         :type        => :bool

  option :no_noop,
         :arguments   => ["--no-noop"],
         :description => "Do a run with noop disabled",
         :type        => :bool

  option :environment,
         :arguments   => ["--environment ENVIRONMENT"],
         :description => "Place the node in a specific environment for this run",
         :type        => String

  option :splay,
         :arguments   => ["--splay"],
         :description => "Splay the run by up to splaylimit seconds",
         :type        => :bool

  option :no_splay,
         :arguments   => ["--no-splay"],
         :description => "Do a run with splay disabled",
         :type        => :bool

  option :splaylimit,
         :arguments   => ["--splaylimit SECONDS"],
         :description => "Maximum splay time for this run if splay is set",
         :type        => Integer

  def raise_message(message, *args)
    messages = {1 => "Action must be count, enable, disable, runall, runonce, status or summary",
                2 => "Please specify a command.",
                3 => "Cannot set splay when forcing runs",
                4 => "Cannot set splaylimit when forcing runs",
                5 => "The runall command needs a concurrency limit",
                6 => "Do not know how to handle the '%s' command",
                7 => "The concurrency for the runall command has to be greater than 0",
                8 => "The runall command cannot be used with compound or -S filters on the CLI"}

    raise messages[message] % args
  end

  def post_option_parser(configuration)
    if ARGV.length >= 1
      configuration[:command] = ARGV.shift

      if arg = ARGV.shift
        if configuration[:command] == "runall"
          configuration[:concurrency] = Integer(arg)

        elsif configuration[:command] == "disable"
          configuration[:message] = arg
        end
      end

      unless ["count", "runonce", "enable", "disable", "runall", "status", "summary"].include?(configuration[:command])
        raise_message(1)
      end
    else
      raise_message(2)
    end
  end

  def validate_configuration(configuration)
    if configuration[:force]
      raise_message(3) if configuration.include?(:splay)
      raise_message(4) if configuration.include?(:splaylimit)
    end

    if configuration[:command] == "runall"
      if configuration[:concurrency]
        raise_message(7) unless configuration[:concurrency] > 0
      else
        raise_message(5)
      end
    end

    configuration[:noop] = false if configuration[:no_noop]
    configuration[:splay] = false if configuration[:no_splay]
  end

  def client
    @client ||= rpcclient("puppet")
  end

  def extract_values_from_aggregates(aggregate_summary)
    counts = {}

    client.stats.aggregate_summary.each do |aggr|
      counts[aggr.result[:output]] = aggr.result[:value]
    end

    counts
  end

  def calculate_longest_hostname(results)
    results.map{|s| s[:sender]}.map{|s| s.length}.max
  end

  def display_results_single_field(results, field)
    return false if results.empty?

    sender_width = calculate_longest_hostname(results) + 3
    pattern = "%%%ds: %%s" % sender_width

    Array(results).each do |result|
      if result[:statuscode] == 0
        puts pattern % [result[:sender], result[:data][field]]
      else
        puts pattern % [result[:sender], MCollective::Util.colorize(:red, result[:statusmsg])]
      end
    end
  end

  def runonce_arguments
    arguments = {}

    [:force, :server, :noop, :environment, :splay, :splaylimit].each do |arg|
      arguments[arg] = configuration[arg] if configuration.include?(arg)
    end

    arguments[:tags] = Array(configuration[:tag]).join(",") if configuration.include?(:tag)

    arguments
  end

  def runall_command(runner=nil)
    raise_message(8) unless client.filter["compound"].empty?

    unless runner
      require 'mcollective/util/puppetrunner.rb'

      runner = MCollective::Util::Puppetrunner.new(client, configuration)
    end

    runner.logger do |msg|
      puts "%s: %s" % [Time.now.strftime("%F %T"), msg]
    end

    runner.runall
  end

  def summary_command
    client.last_run_summary

    puts

    printrpcstats :summarize => true

    halt client.stats
  end

  def status_command
    display_results_single_field(client.status, :message)

    puts

    printrpcstats :summarize => true

    halt client.stats
  end

  def enable_command
    printrpc client.enable
    printrpcstats :summarize => true
    halt client.stats
  end

  def disable_command
    args = {}
    args[:message] = configuration[:message] if configuration[:message]

    printrpc client.disable(args)

    printrpcstats :summarize => true
    halt client.stats
  end

  def runonce_command
    printrpc client.runonce(runonce_arguments)

    printrpcstats

    halt client.stats
  end

  def count_command
    client.progress = false
    client.status

    counts = extract_values_from_aggregates(client.stats.aggregate_summary)

    puts "Total Puppet nodes: %d" % client.stats.okcount
    puts
    puts "          Nodes currently enabled: %d" % counts[:enabled].fetch("enabled", 0)
    puts "         Nodes currently disabled: %d" % counts[:enabled].fetch("disabled", 0)
    puts
    puts "Nodes currently doing puppet runs: %d" % counts[:applying].fetch(true, 0)
    puts "          Nodes currently stopped: %d" % counts[:applying].fetch(false, 0)
    puts
    puts "       Nodes with daemons started: %d" % counts[:daemon_present].fetch("running", 0)
    puts "    Nodes without daemons started: %d" % counts[:daemon_present].fetch("stopped", 0)
    puts "       Daemons started but idling: %d" % counts[:idling].fetch(true, 0)
    puts

    if client.stats.failcount > 0
      puts MCollective::Util.colorize(:red, "Failed to retrieve status of %d %s" % [client.stats.failcount, client.stats.failcount == 1 ? "node" : "nodes"])
    end

    halt client.stats
  end

  def main
    impl_method = "%s_command" % configuration[:command]

    if respond_to?(impl_method)
      send(impl_method)
    else
      raise_message(6, configuration[:command])
    end
  end
end