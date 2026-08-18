# frozen_string_literal: true

require_relative "ir"
require_relative "simplify"

module Rubycc
  module IR
    # One function's instruction list, counted once and handed to everyone who
    # needs the count.
    #
    # Three consumers ask the same questions of the same flat list: IR::Simplify
    # decides its rewrites from how often each virtual register is read and
    # written, IR::Promotion decides which registers are worth a machine
    # register from the same counts plus the transient set, and a backend needs
    # that transient set again on every store it emits. Each of them used to
    # walk the list for itself — the census three times over, the transient set
    # twice, the "is every op one we recognize?" test four times — so a function
    # was scanned a dozen times to answer four questions.
    #
    # This object is that answer, computed once on the way through and passed
    # along: IR::Analysis.simplified runs the rewrites and keeps the census they
    # maintained, and Compiler hands the result straight to the backend. Nothing
    # here decides anything — every rule still lives in Simplify and Promotion —
    # and nothing is cached that the list could invalidate, because a rewritten
    # list gets an object of its own.
    class Analysis
      # `function` is the list this census describes (the *rewritten* one, where
      # a rewrite happened), and `known` says whether every op in it is one
      # IR::Simplify can enumerate the reads of. When it is false the counts are
      # not to be trusted and every consumer refuses the function outright,
      # which is the same fail-safe #run applies.
      attr_reader :function, :insts, :param_count, :vreg_count, :reads, :writes

      # The census of a function nothing has rewritten — what a backend handed a
      # function directly (a test, or any caller that skips the pass) has to
      # fall back on.
      def self.of(function)
        reads, writes = Simplify.census(function.insts, function.vreg_count)
        new(function, reads, writes)
      end

      # IR::Simplify.run, plus the census the rewrites kept true as they went.
      def self.simplified(function)
        rewritten, reads, writes = Simplify.run_counted(function)
        new(rewritten, reads, writes)
      end

      def initialize(function, reads, writes)
        @function = function
        @insts = function.insts
        @param_count = function.param_count
        @vreg_count = function.vreg_count
        @reads = reads
        @writes = writes
      end

      # Whether every op in the list is one whose reads IR::Simplify can
      # enumerate. A function containing anything else is refused whole, by the
      # pass and by every consumer of this object.
      def known?
        !@reads.nil?
      end

      # The transient virtual registers (IR::Simplify#transient_flags), as an
      # array indexed by register number. Computed on first ask and kept, which
      # is what stops IR::Promotion and the backend from computing it twice for
      # the same list.
      def transient
        @transient ||=
          if known?
            Simplify.transient_flags(@insts, @param_count, @reads, @writes, @vreg_count)
          else
            EMPTY_FLAGS
          end
      end

      # The answer for a function with no transient at all. Frozen and shared:
      # every read of it is an index that finds nothing.
      EMPTY_FLAGS = [].freeze
    end
  end
end
