module Wool
  class Runner
    attr_accessor :using, :fix
    
    def initialize(argv)
      @argv = argv
      @using = [:all]
      @fix = [:all]
    end

    def run
      settings, files = collect_options_and_arguments
      settings[:__using__] = warnings_to_consider
      scanner = Wool::Scanner.new(settings)
      warnings = collect_warnings(files, scanner)
      display_warnings(warnings, settings)
    end
    
    def collect_options_and_arguments
      swizzling_argv do
        settings = get_settings
        p settings if settings[:debug]
        files = ARGV.dup
        [settings, files]
      end
    end

    # Parses the command-line options using Trollop
    #
    # @return [Hash{Symbol => Object}] the settings entered by the user
    def get_settings
      warning_opts = get_warning_options
      Trollop::options do
        banner 'Ask Peeves - the Ruby Linter'
        opt :fix, 'Should errors be fixed in-line?', :short => '-f'
        opt :"report-fixed", 'Should fixed errors be reported anyway?', :short => '-r'
        warning_opts.each { |warning| opt(*warning) }
      end
    end
    
    # Gets all the options from the warning plugins and collects them
    # with overriding rules. The later the declaration is run, the higher the
    # priority the option has.
    def get_warning_options
      all_options = Wool::Warning.all_warnings.inject({}) do |result, warning|
        options = warning.options
        options = [options] if options.any? && !options[0].is_a?(Array)
        options.each do |option|
          result[option.first] = option
        end
        result
      end
      all_options.values
    end
    
    # Converts a list of warnings and symbol shortcuts for warnings to just a
    # list of warnings.
    def convert_warning_list(list)
      list.map do |list|
        case list
        when :all then Wool::Warning.all_warnings
        when :whitespace
          [Wool::ExtraBlankLinesWarning, Wool::ExtraWhitespaceWarning,
           Wool::OperatorSpacing, Wool::MisalignedUnindentationWarning]
        else list
        end
      end.flatten
    end
    
    # Returns the list of warnings the user has activated for use.
    def warnings_to_consider
      convert_warning_list(@using)
    end
    
    # Returns the list of warnings the user has selected for fixing
    def warnings_to_fix
      convert_warning_list(@fix)
    end
    
    # Sets the ARGV variable to the runner's arguments during the execution
    # of the block.
    def swizzling_argv
      old_argv = ARGV.dup
      ARGV.replace @argv
      yield
    ensure
      ARGV.replace old_argv
    end

    # Collects warnings from all the provided files by running them through
    # the scanner.
    #
    # @param [Array<String>] files the files to scan. If (stdin) is in the
    #   array, then data will be read from STDIN until EOF is reached.
    # @param [Wool::Scanner] scanner the scanner that will look for warnings
    #   in the source text.
    # @return [Array<Wool::Warning>] a set of warnings, ordered by file.
    def collect_warnings(files, scanner)
      full_list = files.map do |file|
        data = file == '(stdin)' ? STDIN.read : File.read(file)
        scanner.settings[:output_file] = File.open(file, 'w') if scanner.settings[:fix]
        results = scanner.scan(data, file)
        scanner.settings[:output_file].close if scanner.settings[:fix]
        results
      end
      full_list.flatten
    end

    # Displays warnings using user-provided settings.
    #
    # @param [Array<Wool::Warning>] warnings the warnings generated by the input
    #   files, ordered by file
    # @param [Hash{Symbol => Object}] settings the user-set display settings
    def display_warnings(warnings, settings)
      num_fixable = warnings.select { |warning| warning.body != warning.fix(nil) }.size
      num_total = warnings.size

      results = "#{num_total} warnings found. #{num_fixable} are fixable."
      puts results
      puts "=" * results.size

      warnings.each do |warning|
        puts "#{warning.file}:#{warning.line_number} #{warning.name} (#{warning.severity}) - #{warning.desc}"
      end
    end
  end
end