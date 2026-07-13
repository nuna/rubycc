# frozen_string_literal: true

module Rubycc
  module Link
    # Raised for a link-time defect the user must fix: a symbol defined by two
    # inputs, or an input construct the linker does not yet support (a COMMON
    # symbol). It is deliberately not a CompileError — nothing here parses C; the
    # failure belongs to the link stage and names the objects involved so the
    # user can locate the conflict. A malformed input object/archive surfaces as
    # the reader's ELFFormatError / ArFormatError instead.
    class LinkError < Rubycc::Error; end
  end
end
