/* The one compiled function of the stand-in package.
   The tests replace the number in the line that starts with "#define". */
#include <R.h>
#include <Rinternals.h>

#define STANDIN_ANSWER 1

SEXP C_standin_answer(void)
{
    return ScalarInteger(STANDIN_ANSWER);
}
