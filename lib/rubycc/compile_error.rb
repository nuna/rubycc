# frozen_string_literal: true

module Rubycc
  # Base error class (also defined in rubycc.rb; reopened here so this file can
  # be required standalone).
  class Error < StandardError; end

  # A diagnostic raised for any user-facing compilation failure (lexing,
  # parsing, ...). Carries enough source location information (N3) to render a
  # gcc-style message with a caret pointing at the offending column.
  class CompileError < Error
    attr_reader :description, :filename, :line, :column, :source_line

    # description:: the short error text, e.g. "expected ';'"
    # filename::    the source file name for the message header
    # line::        1-based line number
    # column::      1-based column number
    # source_line:: the full text of the offending source line (no newline)
    def initialize(description, filename:, line:, column:, source_line:)
      @description = description
      @filename = filename
      @line = line
      @column = column
      @source_line = source_line
      super(build_message)
    end

    private

    def build_message
      header = "#{filename}:#{line}:#{column}: error: #{description}"
      caret = "#{" " * (column - 1)}^"
      "#{header}\n#{source_line}\n#{caret}"
    end
  end
end
