/* Step 26: conditional compilation and object-like macros.
   Pulls in a config header by quote include, selects a weight constant with an
   #if / #elif / #else chain driven by a macro, redefines a macro after #undef,
   guards a block with #if defined(...) && ..., and folds the macros into a
   printf. Uses only Step 26 preprocessor features (object macros and the
   conditional directives); function-like macros, # / ## and predefined macros
   arrive in Step 27. */
#include "step26_config.h"

int printf(const char *format, ...);

#if TARGET_LEVEL == 1
#define WEIGHT 10
#elif TARGET_LEVEL == 3
#define WEIGHT 30
#else
#define WEIGHT 0
#endif

/* Override a header default: the later definition wins after #undef. */
#undef BUDGET
#define BUDGET 42

int main(void) {
#if defined(ENABLE_TUNING) && ENABLE_TUNING
    int score = WEIGHT + BUDGET - TARGET_LEVEL * 10;
#else
    int score = 0;
#endif
    printf("level=%d weight=%d budget=%d score=%d\n",
           TARGET_LEVEL, WEIGHT, BUDGET, score);
    return score;
}
