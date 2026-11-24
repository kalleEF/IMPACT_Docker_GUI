# Reference copy of `docker_setup`

Every model repository of the IMPACT models (for example GLP1, Meat and Base) carries a
folder `docker_setup`. The IMPACT Docker GUI builds the model image from the folder in the
model repository. This folder is the reference copy of it: the version that the GUI code and
the tests in `tests/docker_setup/` of this repository are written for. `README.md` describes
the folder itself.

Two files exist only here:

- `REFERENCE.md`, this file;
- `dockerignore_for_repository_root`, the text of the file `.dockerignore` that lies at the
  top of every model repository, next to `docker_setup`.

`impact_model.json` here carries the values of the Base model, and `Dockerfile.IMPACTncdGER`
is the one of the Base model repository. The other model repositories keep their own values
in `impact_model.json` (see `README.md`, section 5).

How the copies are kept in step:

1. A change is made here first, on a branch, and must pass the tests:
   `bash tests/docker_setup/run-tests.sh` (they also run on GitHub for every push that
   changes `docker_setup/` or `tests/docker_setup/`).
2. Then the change goes into every model repository and every branch used with the GUI:
   the changed files of this folder, except the two files above, and
   `dockerignore_for_repository_root` as `.dockerignore` at the top of the repository. A
   model repository whose `Dockerfile.IMPACTncdGER` differs from this one gets the same
   change by hand.
3. A change that was made in a model repository first is copied back here, and tested here.
4. When a change alters what the GUI can expect from an image, raise `setup_version` in
   `impact_model.json` and the label `impact.setup_version` in `Dockerfile.IMPACTncdGER`
   together, in every copy.

To check that a model repository is in step, compare its folder with this one, for example
`git diff --no-index --stat <GUI repository>/docker_setup <model repository>/docker_setup`.
Only `impact_model.json`, the two files above and, for a model whose Dockerfile has lines of
its own (for example another repository name), those lines of `Dockerfile.IMPACTncdGER` may
differ.
