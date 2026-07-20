# frozen_string_literal: true

require_relative "test_helper"

# Differential execution tests for AAPCS64 argument passing.
#
# The register budget an argument list draws on is target knowledge, and the
# generator now uses this target's — eight integer registers (x0..x7) and eight
# vector ones (v0..v7) — instead of System V AMD64's six and eight. Everything
# that follows from that is a boundary: which argument is the last to reach a
# register, which is the first to land in the outgoing argument area, and
# whether the callee reads it back from where the caller wrote it. An off-by-one
# in any of those produces code that assembles cleanly and computes garbage, so
# the checks here are differential — the same source built for aarch64 by rubycc
# and by the cross gcc, both linked statically, both run under qemu-aarch64, the
# two runs required to agree on exit status and stdout.
#
# Each argument's contribution to the result is weighted by its position, so a
# callee reading the wrong argument (rather than merely a wrong count of them)
# changes the printed value too.
class TestAArch64ArgumentExecution < Minitest::Test
  include ExecutionHelper
  include AArch64ExecutionHelper

  # --- integer arguments ---------------------------------------------------

  # Seven and eight integer arguments both fit in x0..x7 under AAPCS64, though
  # System V would have spilled the seventh. This is the case that used to stop
  # the backend, and it is checked one argument at a time around the boundary.
  def test_integer_arguments_up_to_the_eighth_register
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      int a7(int a,int b,int c,int d,int e,int f,int g){
        return a+b*2+c*3+d*4+e*5+f*6+g*7;
      }
      int a8(int a,int b,int c,int d,int e,int f,int g,int h){
        return a+b*2+c*3+d*4+e*5+f*6+g*7+h*8;
      }
      int main(void){
        printf("%d\\n", a7(1,2,3,4,5,6,7));
        printf("%d\\n", a8(1,2,3,4,5,6,7,8));
        printf("%d\\n", a7(-1,-2,-3,-4,-5,-6,-7));
        printf("%d\\n", a8(100,200,300,400,500,600,700,800));
        return 0;
      }
    C
  end

  # The ninth and tenth integer arguments are the first to reach the outgoing
  # argument area, so this is the first case in which the caller's stores and
  # the callee's loads have to name the same addresses.
  def test_integer_arguments_past_the_registers
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      int a9(int a,int b,int c,int d,int e,int f,int g,int h,int i){
        return a+b*2+c*3+d*4+e*5+f*6+g*7+h*8+i*9;
      }
      int a10(int a,int b,int c,int d,int e,int f,int g,int h,int i,int j){
        return a+b*2+c*3+d*4+e*5+f*6+g*7+h*8+i*9+j*10;
      }
      int main(void){
        printf("%d\\n", a9(1,2,3,4,5,6,7,8,9));
        printf("%d\\n", a10(1,2,3,4,5,6,7,8,9,10));
        printf("%d\\n", a10(10,9,8,7,6,5,4,3,2,1));
        printf("%d\\n", a9(0,0,0,0,0,0,0,0,-5));
        printf("%d\\n", a10(0,0,0,0,0,0,0,0,0,-7));
        return 0;
      }
    C
  end

  # A stack argument is moved as a whole eightbyte, so a type narrower than
  # eight bytes and a signed one have to survive the trip: the callee re-derives
  # its value from the low bytes exactly as it does for a register argument.
  def test_narrow_and_wide_stack_arguments
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      long mixed(int a,int b,int c,int d,int e,int f,int g,int h,
                 char i,short j,long k,unsigned int l){
        return (long)a+b+c+d+e+f+g+h+i+j+k+(long)l;
      }
      int main(void){
        printf("%ld\\n", mixed(1,2,3,4,5,6,7,8,-9,-10,1234567890123L,4000000000u));
        printf("%ld\\n", mixed(0,0,0,0,0,0,0,0,127,-32768,-1L,1u));
        return 0;
      }
    C
  end

  # A pointer passed on the stack has to arrive intact to all 64 bits, which the
  # eightbyte move is what guarantees.
  def test_pointer_arguments_on_the_stack
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      int deref(int a,int b,int c,int d,int e,int f,int g,int h,int *p,int *q){
        return a+b+c+d+e+f+g+h+*p+*q;
      }
      int main(void){
        int x = 100, y = 200;
        printf("%d\\n", deref(1,2,3,4,5,6,7,8,&x,&y));
        return 0;
      }
    C
  end

  # --- floating arguments --------------------------------------------------

  # Eight doubles fill v0..v7; the ninth and tenth spill. The vector sequence
  # runs its own counter, so its boundary is independent of the integer one.
  def test_floating_arguments_around_the_vector_registers
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      double d8(double a,double b,double c,double d,double e,double f,double g,double h){
        return a+b*2+c*3+d*4+e*5+f*6+g*7+h*8;
      }
      double d9(double a,double b,double c,double d,double e,double f,double g,double h,
                double i){
        return a+b*2+c*3+d*4+e*5+f*6+g*7+h*8+i*9;
      }
      double d10(double a,double b,double c,double d,double e,double f,double g,double h,
                 double i,double j){
        return a+b*2+c*3+d*4+e*5+f*6+g*7+h*8+i*9+j*10;
      }
      int main(void){
        printf("%f\\n", d8(1,2,3,4,5,6,7,8));
        printf("%f\\n", d9(1,2,3,4,5,6,7,8,9));
        printf("%f\\n", d10(1,2,3,4,5,6,7,8,9,10));
        printf("%f\\n", d10(0.5,1.5,2.5,3.5,4.5,5.5,6.5,7.5,8.5,9.5));
        return 0;
      }
    C
  end

  # A stack-passed `float` travels in an eightbyte of which only the low four
  # bytes are meaningful, so this checks that the callee reads back the single
  # it was given and not the indeterminate high half alongside it.
  def test_single_precision_arguments_on_the_stack
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      float f10(float a,float b,float c,float d,float e,float f,float g,float h,
                float i,float j){
        return a+b*2+c*3+d*4+e*5+f*6+g*7+h*8+i*9+j*10;
      }
      int main(void){
        printf("%.4f\\n", f10(1,2,3,4,5,6,7,8,9,10));
        printf("%.4f\\n", f10(0.25f,0.5f,0.75f,1.25f,1.5f,1.75f,2.25f,2.5f,2.75f,3.25f));
        return 0;
      }
    C
  end

  # --- mixed sequences -----------------------------------------------------

  # Integers and doubles interleaved, with each sequence run past its own end:
  # twelve of each means four integers and four doubles reach the stack, and
  # they have to interleave there in source order, not class order.
  def test_mixed_integer_and_floating_arguments_both_overflow
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      double mix(int a,double b,int c,double d,int e,double f,int g,double h,
                 int i,double j,int k,double l,int m,double n,int o,double p,
                 int q,double r,int s,double t,int u,double v,int w,double x){
        return a+b*2+c*3+d*4+e*5+f*6+g*7+h*8+i*9+j*10+k*11+l*12
             + m*13+n*14+o*15+p*16+q*17+r*18+s*19+t*20+u*21+v*22+w*23+x*24;
      }
      int main(void){
        printf("%f\\n", mix(1,2,3,4,5,6,7,8,9,10,11,12,
                            13,14,15,16,17,18,19,20,21,22,23,24));
        return 0;
      }
    C
  end

  # Only the integer sequence overflows: the doubles all stay in v0..v7 while
  # the last integers go to the stack, so the two placements have to be counted
  # separately rather than from one running index.
  def test_only_the_integer_sequence_overflows
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      double g(int a,int b,int c,int d,int e,int f,int g2,int h,int i,int j,
               double x,double y){
        return a+b*2+c*3+d*4+e*5+f*6+g2*7+h*8+i*9+j*10+x*11+y*12;
      }
      int main(void){
        printf("%f\\n", g(1,2,3,4,5,6,7,8,9,10,11.5,12.5));
        return 0;
      }
    C
  end

  # And the mirror image: the doubles overflow while every integer stays in a
  # register.
  def test_only_the_floating_sequence_overflows
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      double g(double a,double b,double c,double d,double e,double f,double g2,double h,
               double i,double j,int x,int y){
        return a+b*2+c*3+d*4+e*5+f*6+g2*7+h*8+i*9+j*10+x*11+y*12;
      }
      int main(void){
        printf("%f\\n", g(1,2,3,4,5,6,7,8,9,10,11,12));
        return 0;
      }
    C
  end

  # --- variadic and indirect calls -----------------------------------------

  # A variadic callee places its arguments in the same registers a fixed one
  # would under AAPCS64, so printf with many values exercises the same boundary
  # from the caller's side alone — and printf itself is the oracle for where
  # each value ended up. The seven-integer line is the shape that used to stop
  # the backend outright.
  def test_variadic_calls_with_many_arguments
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      int main(void){
        int a=1,b=2,c=3,d=4,e=5,f=6;
        printf("%d %d %d %d %d %d\\n", a, b, c, d, e, f);
        printf("%d %d %d %d %d %d %d %d %d %d\\n", 1,2,3,4,5,6,7,8,9,10);
        printf("%f %f %f %f %f %f %f %f %f %f\\n",
               1.5,2.5,3.5,4.5,5.5,6.5,7.5,8.5,9.5,10.5);
        printf("%d %f %d %f %d %f %d %f %d %f\\n",
               1,1.5,2,2.5,3,3.5,4,4.5,5,5.5);
        printf("%s %d %s %d %s %d %s %d\\n", "a",1,"b",2,"c",3,"d",4);
        return 0;
      }
    C
  end

  # The same argument placement reached through a function pointer, where the
  # callee's address is a run-time value the argument setup must not disturb.
  def test_indirect_calls_with_many_arguments
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      int a10(int a,int b,int c,int d,int e,int f,int g,int h,int i,int j){
        return a+b*2+c*3+d*4+e*5+f*6+g*7+h*8+i*9+j*10;
      }
      double m10(int a,double b,int c,double d,int e,double f,int g,double h,
                 int i,double j){
        return a+b*2+c*3+d*4+e*5+f*6+g*7+h*8+i*9+j*10;
      }
      int main(void){
        int (*p)(int,int,int,int,int,int,int,int,int,int) = a10;
        double (*q)(int,double,int,double,int,double,int,double,int,double) = m10;
        printf("%d\\n", p(1,2,3,4,5,6,7,8,9,10));
        printf("%d\\n", p(10,9,8,7,6,5,4,3,2,1));
        printf("%f\\n", q(1,2,3,4,5,6,7,8,9,10));
        return 0;
      }
    C
  end

  # --- interaction with the frame ------------------------------------------

  # Reserving the outgoing argument area moves every slot in the frame, so a
  # function that both passes stack arguments and keeps locals, arrays and
  # taken addresses across the call has to find all of them unchanged
  # afterwards. Calling twice with different counts also checks that the one
  # area is sized for the widest call rather than the first.
  def test_stack_arguments_do_not_disturb_the_frame
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      int a9(int a,int b,int c,int d,int e,int f,int g,int h,int i){
        return a+b+c+d+e+f+g+h+i;
      }
      int a12(int a,int b,int c,int d,int e,int f,int g,int h,int i,int j,int k,int l){
        return a+b+c+d+e+f+g+h+i+j+k+l;
      }
      int main(void){
        int table[16];
        int i;
        int local = 4242;
        int *p = &local;
        for (i = 0; i < 16; i++) table[i] = i * i;
        int first = a9(1,2,3,4,5,6,7,8,9);
        int second = a12(1,2,3,4,5,6,7,8,9,10,11,12);
        int sum = 0;
        for (i = 0; i < 16; i++) sum += table[i];
        printf("%d %d %d %d %d\\n", first, second, sum, local, *p);
        return 0;
      }
    C
  end

  # A recursive function passing stack arguments: each level reserves its own
  # outgoing area and reads its own incoming one, so the two must not overlap.
  def test_recursion_through_stack_arguments
    assert_aarch64_matches_gcc(<<~C)
      #include <stdio.h>
      int depth(int n,int a,int b,int c,int d,int e,int f,int g,int h,int i){
        if (n == 0) return a+b+c+d+e+f+g+h+i;
        return depth(n-1,a+1,b+1,c+1,d+1,e+1,f+1,g+1,h+1,i+1);
      }
      int main(void){
        printf("%d\\n", depth(0,1,2,3,4,5,6,7,8,9));
        printf("%d\\n", depth(5,1,2,3,4,5,6,7,8,9));
        printf("%d\\n", depth(20,0,0,0,0,0,0,0,0,0));
        return 0;
      }
    C
  end
end
