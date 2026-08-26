# frozen_string_literal: true
# token-representation-measurement の測定。実装はしない。
#   (1) 変換 (PPToken -> Front::Token) が全体に占める時間
#   (2) 各表現の生成個数と、1 コンパイルあたりの総オブジェクト数
#   (3) 変換を完全になくせた場合の上限
$LOAD_PATH.unshift(File.expand_path("lib", __dir__ || "."))
require "rubycc"
require "rbconfig"

RUNS = Integer(ENV.fetch("RUNS", "5"))
def monotime = Process.clock_gettime(Process::CLOCK_MONOTONIC)
def median(a) = (s = a.sort; s.length.odd? ? s[s.length / 2] : (s[s.length / 2 - 1] + s[s.length / 2]) / 2.0)

c = RbConfig::CONFIG
HDRS = [c["rubyarchhdrdir"], "#{c['rubyhdrdir']}/ruby/backward", c["rubyhdrdir"]].freeze
JSON_DIR = "/tmp/rubycc_bench/tp-json-2.21.1/ext/json/ext/parser"

WORKLOADS = []
if File.exist?(File.join(JSON_DIR, "parser.c"))
  WORKLOADS << { name: "json parser.c", path: File.join(JSON_DIR, "parser.c"), inc: [JSON_DIR, *HDRS] }
end
ruby_h = File.join(Dir.tmpdir, "rubycc_measure_ruby_h.c")
File.write(ruby_h, "#include <ruby.h>\nvoid Init_probe(void) { rb_define_module(\"Probe\"); }\n")
WORKLOADS << { name: "#include <ruby.h>", path: ruby_h, inc: HDRS }

ENTRY = Rubycc::Compiler::TARGETS.fetch("x86_64")
def new_pp = Rubycc::Preprocess::Preprocessor.new(char_unsigned: !ENTRY[:char_signed],
                                                  arch_macros: ENTRY[:arch_macros],
                                                  libc_arch: ENTRY[:libc_arch])

# (1) 段階別の時間。Compiler#compile と同じ順で、変換だけを切り出して測る。
def stages(source, path, inc)
  t0 = monotime
  pp_tokens = new_pp.preprocess(source, filename: path, include_paths: inc, defines: [])
  t1 = monotime
  tokens = Rubycc::Preprocess::TokenConverter.new.convert(pp_tokens)
  t2 = monotime
  plain_char = Rubycc::Type.plain_char(ENTRY[:char_signed])
  program = Rubycc::Front::Parser.new(tokens, plain_char: plain_char,
                                      unnamed_bitfields_align: ENTRY[:unnamed_bitfields_align],
                                      builtin_va_list: ENTRY[:convention].va_list_type).parse
  t3 = monotime
  Rubycc::IR::Generator.new(plain_char: plain_char, convention: ENTRY[:convention]).generate(program, pic: true)
  t4 = monotime
  { preprocess: t1 - t0, convert: t2 - t1, parse: t3 - t2, ir: t4 - t3,
    pp_tokens: pp_tokens.length, tokens: tokens.length }
end

def full(source, path, inc)
  t = monotime
  Rubycc::Compiler.new.compile(source, filename: path, include_paths: inc, defines: [], pic: true)
  monotime - t
end

puts "Ruby #{RUBY_VERSION} (YJIT #{defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? 'on' : 'off'}), RUNS=#{RUNS}"
WORKLOADS.each do |w|
  src = File.read(w[:path])
  full(src, w[:path], w[:inc]) # warmup
  fulls = RUNS.times.map { full(src, w[:path], w[:inc]) }
  st = RUNS.times.map { stages(src, w[:path], w[:inc]) }
  med = ->(k) { median(st.map { |h| h[k] }) }
  total = med.(:preprocess) + med.(:convert) + med.(:parse) + med.(:ir)
  fm = median(fulls)

  # (2) 生成個数。カウンタは時間計測とは別のパスで入れる(オーバーヘッドを混ぜない)。
  before = GC.stat(:total_allocated_objects)
  counts = { pp: 0, tok: 0 }
  [[Rubycc::Preprocess::PPToken, :pp], [Rubycc::Front::Token, :tok]].each do |klass, key|
    klass.singleton_class.prepend(Module.new do
      define_method(:new) { |*a, **kw, &b| counts[key] += 1; super(*a, **kw, &b) }
    end)
  end
  Rubycc::Compiler.new.compile(src, filename: w[:path], include_paths: w[:inc], defines: [], pic: true)
  allocated = GC.stat(:total_allocated_objects) - before

  puts
  puts "== #{w[:name]}"
  puts "  full compile (median of #{RUNS})   : #{'%.1f' % (fm * 1000)} ms"
  %i[preprocess convert parse ir].each do |k|
    puts "  #{k.to_s.ljust(10)}                     : #{'%.1f' % (med.(k) * 1000)} ms  (段階計の #{'%.1f' % (med.(k) / total * 100)}%, full の #{'%.1f' % (med.(k) / fm * 100)}%)"
  end
  puts "  PPToken 生成                       : #{counts[:pp]}"
  puts "  Front::Token 生成                  : #{counts[:tok]}"
  puts "  1 コンパイルの総オブジェクト生成   : #{allocated}"
  puts "  → 変換を完全になくせた場合の上限   : full の #{'%.1f' % (med.(:convert) / fm * 100)}% 短縮"
end
