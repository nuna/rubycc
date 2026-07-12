/* Step 27 logging header, pulled in by a quote #include from step27_report.c.
   Demonstrates the function-like macro machinery completed in Step 27: a
   "#pragma once" guard, argument-substituting macros (MAX / MIN), a stringizing
   check macro (# operator), token pasting (## operator) to build an identifier,
   and a __VA_ARGS__ forwarder to printf. Uses only Step 27 features. */
#pragma once

/* Parenthesize every argument and the whole body so the macro composes safely
   inside larger expressions (the textbook function-like macro hygiene). */
#define MAX(a, b) ((a) > (b) ? (a) : (b))
#define MIN(a, b) ((a) < (b) ? (a) : (b))

/* "#expr" turns the unexpanded argument into a string literal, so the printed
   label is the source spelling of whatever expression was measured. */
#define SHOW(expr) printf("%s = %d\n", #expr, (expr))

/* "counter_ ## name" pastes the prefix onto the name to synthesize a fresh
   identifier at the use site. */
#define COUNTER(name) counter_ ## name

/* Forward a caller's format and variable arguments straight to printf. */
#define LOG(fmt, ...) printf(fmt, __VA_ARGS__)
