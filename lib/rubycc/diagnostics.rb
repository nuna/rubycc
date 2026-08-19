# frozen_string_literal: true

module Rubycc
  # The compiler's diagnostic channel: one renderer for every severity, and the
  # stream the non-fatal ones are written to.
  #
  # Until `#warning` there was only one severity here. A diagnostic was a raised
  # CompileError and nothing else, so "report it" and "give up on this
  # translation unit" were the same act, and several places in the front end say
  # so ("a warning is not a channel this compiler has"). `#warning` needs the
  # other half: a located message that is reported and then *returned from*, so
  # the compile continues and exits 0 (C23 6.10.2p2, and gcc's long-standing
  # extension of the same shape).
  #
  # The two halves share #render, so a warning is spelled exactly like an error
  # apart from the severity word — one place to change the format, not two.
  # CompileError renders itself through it (see compile_error.rb); a warning is
  # written straight to the stream, because there is nothing to raise.
  #
  # The stream is process-wide state rather than a parameter threaded through
  # every component, for the reason the first caller shows: the warning is
  # raised deep inside the preprocessor's directive walk, whose callers
  # (Compiler, and the parser and IR generator that will want this channel next)
  # take no stream and have no business growing one. Concurrency does not argue
  # against it here — rmake's `-j` isolates each step in a forked child (see
  # Rmake::Executor), so no two translation units share this state.
  module Diagnostics
    # The stream state when nobody has chosen one: warnings go to the process's
    # $stderr, looked up at emit time so a test (or a caller) that swaps $stderr
    # is honored. It is a distinct object from nil, which means "discard".
    INHERIT = Object.new
    private_constant :INHERIT

    @stream = INHERIT

    class << self
      # A gcc-style diagnostic: the "file:line:column: severity: text" header,
      # the offending source line, and a caret under the offending column.
      # `severity` is the bare word ("error", "warning").
      def render(severity, description, filename:, line:, column:, source_line:)
        header = "#{filename}:#{line}:#{column}: #{severity}: #{description}"
        caret = "#{" " * (column - 1)}^"
        "#{header}\n#{source_line}\n#{caret}"
      end

      # Reports a warning at a source position and returns; the compile goes on.
      # Nothing is written when warnings are being discarded (see .to).
      def warn(description, filename:, line:, column:, source_line:)
        target = stream
        return if target.nil?

        target.puts render("warning", description, filename: filename, line: line,
                                                   column: column, source_line: source_line)
      end

      # Runs the block with warnings written to `stream` — an IO, or nil to
      # discard them (what the driver's `-w` selects). The previous target is
      # restored afterwards, so a nested run (rmake invoking the Driver
      # in-process) leaves nothing behind.
      def to(stream)
        previous = @stream
        @stream = stream
        yield
      ensure
        @stream = previous
      end

      private

      def stream
        @stream.equal?(INHERIT) ? $stderr : @stream
      end
    end
  end
end
