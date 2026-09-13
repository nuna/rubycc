/* unprototyped-function-redeclaration-1: a named function declared old-style
 * ("int area();", unspecified parameters), called before its prototyped
 * definition, and later redeclared with a parameter-type list, per ISO C
 * 6.7.6.3p15 and 6.2.7p3.
 *
 * An old-style declaration and a prototype are compatible when the prototype
 * has no ellipsis and none of its parameter types is changed by the default
 * argument promotions (6.5.2.2p6); the function then has the prototype as its
 * composite type. A call made while only the old-style declaration is visible
 * passes its arguments with those promotions: the char and the float below
 * arrive as int and double, exactly the types the definition declares.
 *
 * Old C headers often carry such "int f();" declarations; rubycc used to stop
 * at the definition with "conflicting types", and at the early call with
 * "too many arguments", although gcc accepts both.
 */
#include <stdio.h>

/* What an old header would say. */
int area();
double average();

int early_area(void) {
    char width = 6;
    return area(width, 7); /* char promoted to int */
}

double early_average(void) {
    float half = 0.5f;
    return average(3, half); /* float promoted to double */
}

/* A later prototype of the same function: compatible, and now in force. */
int area(int, int);

int area(int w, int h) { return w * h; }

double average(int n, double extra) { return (n + extra) / 2.0; }

int main(void) {
    printf("%d %d\n", early_area(), area(2, 5));
    printf("%.2f\n", early_average());
    return 0;
}
