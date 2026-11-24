# Stand-in model repository for the docker_setup tests

This folder plays the part of a model repository (for example IMPACT-NCD-Germany_Base) in
the tests of `tests/docker_setup`. It holds only what the image build and the start-up
scripts look at:

| Entry | Why it is here |
|-------|----------------|
| `IMPACT_Standin_Model.Rproj` | The start-up script looks for an RStudio project file and tells RStudio to open it. |
| `Rpackage/IMPACTncd_Ger_model_pkg/` | The model's Dockerfile builds and installs the R package in this folder. The stand-in package is called `impactstandin` and has one compiled function. |
| `outputs/`, `inputs/synthpop/` | The GUI mounts the result folders at these two places. |

`run-tests.sh` copies the reference `docker_setup` folder next to these entries before it
builds the test image, exactly where a model repository has it.
