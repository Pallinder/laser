module Wool
  class Scanner
    class Context < Struct.new(:type, :data)
      def initialize(*args)
        super
        self.data ||= {}
      end
    end

    attr_accessor :settings
    attr_accessor :context_stack
    attr_accessor :indent_stack

    DEFAULT_SETTINGS = {:fix => false, :output => STDOUT,
                        :__using__ => Wool::Warning.all_warnings}

    # Initializes the scanner with the given settings
    #
    # @param [Hash] settings the settings to use to customize this scanner's
    #   scanning behavior
    def initialize(settings = DEFAULT_SETTINGS)
      @settings = DEFAULT_SETTINGS.merge(settings)
      self.context_stack = []
      self.indent_stack = []
    end

    # Returns the list of warnings to use for scanning.
    def using
      @settings[:__using__]
    end

    # Scans the text for warnings.
    #
    # @param [String] text the input ruby file to scan
    # @return [Array[Wool::Warnings]] the warnings generated by the code.
    #   If the code is clean, an empty array is returned.
    def scan(text, filename='(none)')
      warnings = scan_for_file_warnings(text, filename)
      text.split(/\n/).each_with_index do |line, number|
        warnings.concat process_line(line, number + 1, filename)
      end
      warnings
    end

    def process_line(line, line_number, filename)
      warnings = []
      update_context! line
      new_warnings = check_for_indent_warnings!(line, filename)
      new_warnings.concat scan_for_line_warnings(line, filename)
      new_warnings.each {|warning| warning.line_number = line_number}
      fixable_warnings = new_warnings.select {|warning| warning.fixable? }
      if fixable_warnings.size == 1 && @settings[:fix]
        self.settings[:output_file].puts fixable_warnings.first.fix(self.context_stack)
        warnings << fixable_warnings.first
      elsif fixable_warnings.size > 1 && @settings[:fix]
        warnings << fixable_warnings.first
        warnings.concat process_line(fixable_warnings.first.fix(self.context_stack), line_number, filename)
      elsif @settings[:fix]
        self.settings[:output_file].puts line
      else
        warnings.concat new_warnings
      end
      warnings
    end

    # Checks for new warnings based on indentation.
    def check_for_indent_warnings!(line, filename)
      return [] if line == ""
      indent_size = get_indent_size line
      if indent_size > current_indent
        self.indent_stack.push indent_size
      elsif indent_size < current_indent
        previous = self.indent_stack.pop
        if indent_size != current_indent && 
           using.include?(MisalignedUnindentationWarning)
          return [MisalignedUnindentationWarning.new(filename, line, current_indent)]
        end
      end
      []
    end

    # Gets the current indent size
    def current_indent
      self.indent_stack.last || 0
    end

    # Gets the indent size of a given line
    def get_indent_size(line)
      line.match(/^\s*/)[0].size
    end

    # Updates the context of the scanner right now based on poor heuristics.
    def update_context!(line)
      case line
      when /^\s*class\s+([A-Z][A-Za-z0-9_]*)/
        self.context_stack.push(Context.new(:class, {:class_name => $1}))
      when /^\s*module\s+([A-Z][A-Za-z0-9_]*)/
        self.context_stack.push(Context.new(:module, {:module_name => $1}))
      when /^\s*if([^$]*?)(then)?\s*$/
        self.context_stack.push(Context.new(:if, {:condition => $1.strip}))
      when /^\s*end\b/
        self.context_stack.pop
      end
    end

    # Goes through all file warning subclasses and see what warnings the file
    # generates as a whole.
    def scan_for_file_warnings(file, filename)
      scan_for_warnings(using & FileWarning.all_warnings, file, filename)
    end

    # Goes through all line warning subclasses and checks if we got some new warnings
    # for a given line
    def scan_for_line_warnings(line, filename)
      scan_for_warnings(using & LineWarning.all_warnings, line, filename)
    end

    private

    def scan_for_warnings(warnings, content, filename)
      warnings.inject([]) do |acc, warning|
        if warning.match?(content, self.context_stack, @settings)
          acc << warning.new(filename, content)
        end
        acc
      end
    end
  end
end