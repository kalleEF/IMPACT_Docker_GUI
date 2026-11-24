# Stand-in for roxygen2::roxygenise() and its second spelling roxygenize().
# The real function writes help pages and the NAMESPACE file of a package.
# This one writes nothing and says so.
roxygenise <- function(package.dir = ".", ...) {
  message("roxygen2 stand-in of the docker_setup tests: nothing to do for ", package.dir)
  invisible(NULL)
}
roxygenize <- roxygenise
