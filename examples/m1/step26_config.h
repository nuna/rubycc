/* Step 26 config header, pulled in by a quote #include from step26_selftune.c.
   Demonstrates an object-like macro set behind the classic include guard
   (#ifndef / #define / #endif). Uses only Step 26 preprocessor features: object
   macros and conditional directives — no function-like macros, no # / ##, no
   predefined macros (those arrive in Step 27). */
#ifndef STEP26_CONFIG_H
#define STEP26_CONFIG_H

#define TARGET_LEVEL 3
#define BUDGET 40
#define ENABLE_TUNING 1

#endif
