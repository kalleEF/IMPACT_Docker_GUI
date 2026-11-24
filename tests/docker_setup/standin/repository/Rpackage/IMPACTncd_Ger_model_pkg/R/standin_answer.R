# standin_answer(): returns the number compiled into src/standin.c.
# The tests change that number in the source file, install the package again from an
# RStudio session and expect the new number. That proves the package was compiled anew.
standin_answer <- function() {
  .Call("C_standin_answer", PACKAGE = "impactstandin")
}
